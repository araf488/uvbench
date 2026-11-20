#!/usr/bin/env bash
# Sets up the monitoring server (Prometheus + Grafana).
# Usage (as root, from the kit root):  bash scripts/bootstrap-monitor.sh <loadgen-private-ip>
# Then register each tested server:     bash scripts/monitor-add-target.sh 8c <target-private-ip>
source "$(dirname "$0")/lib.sh"
require_root
LG="${1:?usage: bootstrap-monitor.sh <loadgen-private-ip>}"
base_setup
install_docker
cd "$KIT_DIR/monitoring"

log "Grafana dashboards"
python3 grafana/make_dashboard.py
dl() { # community dashboards, datasource placeholder replaced with our Prometheus uid
  curl -fsSL "https://grafana.com/api/dashboards/$1/revisions/latest/download" \
    | sed 's/\${DS_PROMETHEUS}/prometheus/g; s/\${DS_PROM}/prometheus/g' > "grafana/dashboards/$2.json" \
    || echo "  (could not download dashboard $1, skipped)"
}
dl 1860 node-exporter-full; dl 19665 k6-prometheus; dl 9628 postgresql; dl 763 redis; dl 14282 cadvisor

mkdir -p prometheus/targets
printf '[{"targets":["%s:9100"],"labels":{"tier":"loadgen"}}]\n' "$LG" > prometheus/targets/loadgen-node.json
[ -f .env ] || printf 'GRAFANA_PASSWORD=%s\n' "$(openssl rand -base64 18 | tr -d '/+=')" > .env
chmod 600 .env

log "Starting Prometheus + Grafana"
docker compose --env-file .env up -d
PUB=$(curl -fs4 https://ifconfig.me || hostname -I | awk '{print $1}')
log "Monitoring ready
  Grafana:    http://$PUB:3000   user: admin   password: in $KIT_DIR/monitoring/.env
  Prometheus: http://$PUB:9090   (for safety, both ports are reachable only after: ufw allow from <your-ip> to any port 3000,9090)"
