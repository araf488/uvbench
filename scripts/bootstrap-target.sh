#!/usr/bin/env bash
# Sets up a TEST target server end to end:
#   hardening -> Docker -> .env for the tier -> models -> build -> database seed -> AI knowledge base -> smoke test
# Usage (as root, from the kit root):   bash scripts/bootstrap-target.sh 8c
# Safe to re-run: every step is idempotent.
source "$(dirname "$0")/lib.sh"
require_root
TIER="${1:?usage: bootstrap-target.sh 1c|2c|4c|8c}"
[ -f "$KIT_DIR/tiers/$TIER.env" ] || die "unknown tier $TIER"
cd "$KIT_DIR"
DC="docker compose --env-file .env -f compose/docker-compose.yml"

base_setup
ufw allow 80/tcp >/dev/null
case "$TIER" in 1c) add_swap 2 ;; 2c) add_swap 2 ;; *) add_swap 0 ;; esac
install_docker

PIP="$(private_ip)"
[ -n "$PIP" ] || die "no 10.x private (VPC) address found. Attach the VPC in Vultr, or run: PRIVATE_IP=<ip> bash $0 $TIER"
log "Tier $TIER, private IP $PIP"

# ---- .env (secrets are generated once and kept) ----
SECRETS=/root/.uvbench-secrets
[ -f "$SECRETS" ] || printf 'DB_PASSWORD=%s\nJWT_SECRET=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 32)" > "$SECRETS"
chmod 600 "$SECRETS"
{ cat tiers/common.env "tiers/$TIER.env"; echo "PRIVATE_IP=$PIP"; cat "$SECRETS"; } > .env
chmod 600 .env
set -a; . ./.env; set +a

# ---- cost metric for Prometheus (node-exporter textfile collector) ----
mkdir -p /var/lib/uvbench/textfile
cat > /var/lib/uvbench/textfile/uvbench.prom <<EOF
# HELP uvbench_cost_per_hour_usd Vultr hourly price of this server
# TYPE uvbench_cost_per_hour_usd gauge
uvbench_cost_per_hour_usd{tier="$TIER"} $COST_PER_HOUR
# HELP uvbench_tier_info Tier marker
# TYPE uvbench_tier_info gauge
uvbench_tier_info{tier="$TIER",llm="$LLM_FILE",whisper="$WHISPER_MODEL"} 1
EOF

log "Downloading AI models"
bash scripts/models.sh

if [[ "$IMAGE_PREFIX" == */* ]]; then
  log "Pulling images $IMAGE_PREFIX/*:$IMAGE_TAG (built by GitHub Actions)"
  $DC pull -q
else
  log "Building images on this server (first time takes a few minutes)"
  $DC build
  $DC pull --ignore-buildable -q
fi

log "Starting database and Redis"
$DC up -d db redis
for i in $(seq 60); do $DC exec -T db pg_isready -U bench -d bench >/dev/null 2>&1 && break; sleep 2; done

if [ "$($DC exec -T db psql -U bench -d bench -tAc 'SELECT count(*) FROM products')" -lt "$SEED_PRODUCTS" ]; then
  log "Seeding database ($SEED_USERS users, $SEED_PRODUCTS products, $SEED_ORDERS orders)"
  time $DC exec -T db psql -U bench -d bench -v ON_ERROR_STOP=1 -q \
    -v n_users="$SEED_USERS" -v n_products="$SEED_PRODUCTS" -v n_orders="$SEED_ORDERS" -f /seed/seed.sql
else
  log "Database already seeded"
fi

log "Starting the full stack"
$DC up -d
log "Waiting for AI services (whisper model download on first start)"
for svc in "llm:8080/health" "embed:8082/health" "stt:8001/health" "tts:8003/health"; do
  name=${svc%%:*}; url="http://$PIP:${svc#*:}"
  for i in $(seq 180); do curl -fs "$url" >/dev/null 2>&1 && { echo "  $name ready"; break; }; sleep 5; done
  curl -fs "$url" >/dev/null 2>&1 || { $DC logs --tail 30 "$name"; die "$name did not become healthy"; }
done

log "Seeding AI knowledge base ($SEED_DOCS documents)"
$DC exec -T api node src/seed-docs.js "$SEED_DOCS"

log "Smoke test"
curl -fs -o /dev/null -w "  web /            %{http_code} %{time_total}s\n" http://127.0.0.1/
curl -fs -o /dev/null -w "  web /products/1  %{http_code} %{time_total}s\n" http://127.0.0.1/products/1
curl -fs -w "\n" http://127.0.0.1/api/health
curl -fs -X POST -H 'content-type: application/json' -d '{"question":"How does the laptop warranty work?"}' \
  http://127.0.0.1/api/ai/ask | jq -c '{answer: .answer[0:120], timings}'
$DC ps --format 'table {{.Service}}\t{{.Status}}'
log "Target $TIER is ready. Private IP: $PIP  (give this to the monitoring and load-generator setup)"
