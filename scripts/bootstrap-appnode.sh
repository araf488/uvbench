#!/usr/bin/env bash
# Sets up an APP-ONLY node for scale-out / high availability: web, API, AI worker and AI services, but no
# database or Redis. It uses PostgreSQL + Redis on the "data node" (a normal target, e.g. the first 4c) over the VPC.
#
# One-time prerequisite (from your Mac): copy the data node's secrets so both nodes share DB password + JWT key
#   ssh root@<data-node-public-ip> cat /root/.uvbench-secrets | ssh root@<this-node-public-ip> "cat > /root/.uvbench-secrets"
#
# Usage (as root, from the kit root):  bash scripts/bootstrap-appnode.sh 4c <data-node-private-ip>
source "$(dirname "$0")/lib.sh"
require_root
TIER="${1:?usage: bootstrap-appnode.sh <tier> <data-node-private-ip>}"
DATA="${2:?usage: bootstrap-appnode.sh <tier> <data-node-private-ip>}"
[ -f "$KIT_DIR/tiers/$TIER.env" ] || die "unknown tier $TIER"
[ -s /root/.uvbench-secrets ] || die "copy /root/.uvbench-secrets from the data node first (see the header of this script)"
cd "$KIT_DIR"
DC="docker compose --env-file .env -f compose/docker-compose.yml"
APP_SERVICES="web api worker nginx llm embed stt tts node-exporter cadvisor nginx-exporter"

base_setup
ufw allow 80/tcp >/dev/null
install_docker
PIP="$(private_ip)"; [ -n "$PIP" ] || die "no 10.x VPC address"
log "App node, tier $TIER, private IP $PIP, data node $DATA"

{ cat tiers/common.env "tiers/$TIER.env"; echo "PRIVATE_IP=$PIP"; echo "PG_HOST=$DATA"; echo "REDIS_HOST=$DATA"; cat /root/.uvbench-secrets; } > .env
chmod 600 .env
set -a; . ./.env; set +a

mkdir -p /var/lib/uvbench/textfile
cat > /var/lib/uvbench/textfile/uvbench.prom <<EOF
# TYPE uvbench_cost_per_hour_usd gauge
uvbench_cost_per_hour_usd{tier="${TIER}b"} $COST_PER_HOUR
EOF

log "Checking the data node is reachable"
timeout 5 bash -c "</dev/tcp/$DATA/5432" || die "cannot reach PostgreSQL on $DATA:5432 (is the data node updated and running?)"
timeout 5 bash -c "</dev/tcp/$DATA/6379" || die "cannot reach Redis on $DATA:6379"

log "Downloading AI models"
bash scripts/models.sh

if [[ "$IMAGE_PREFIX" == */* ]]; then $DC pull -q $APP_SERVICES; else $DC build web api stt tts; $DC pull -q --ignore-buildable --ignore-pull-failures $APP_SERVICES; fi

log "Starting app services (no database / Redis here)"
$DC up -d --no-deps $APP_SERVICES
for svc in "llm:8080/health" "embed:8082/health" "stt:8001/health" "tts:8003/health"; do
  name=${svc%%:*}; url="http://$PIP:${svc#*:}"
  for i in $(seq 180); do curl -fs "$url" >/dev/null 2>&1 && { echo "  $name ready"; break; }; sleep 5; done
done

log "Smoke test"
curl -fs -o /dev/null -w "  web /products/1  %{http_code} %{time_total}s\n" http://127.0.0.1/products/1
curl -fs -w "\n" http://127.0.0.1/api/health
log "App node ready. Private IP: $PIP. Register it with: bash scripts/monitor-add-target.sh ${TIER}b $PIP app"
