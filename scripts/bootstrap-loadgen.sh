#!/usr/bin/env bash
# Sets up the load generator: hardening, kernel tuning, k6, voice clips, 24/7 systemd units.
# Usage (as root, from the kit root):  bash scripts/bootstrap-loadgen.sh <monitor-private-ip>
source "$(dirname "$0")/lib.sh"
require_root
MON="${1:?usage: bootstrap-loadgen.sh <monitor-private-ip>}"
K6_VERSION=1.4.2

base_setup
if ! command -v k6 >/dev/null; then
  log "Installing k6 v$K6_VERSION"
  curl -fsSL "https://github.com/grafana/k6/releases/download/v$K6_VERSION/k6-v$K6_VERSION-linux-amd64.tar.gz" \
    | tar xz -C /tmp && install /tmp/k6-v$K6_VERSION-linux-amd64/k6 /usr/local/bin/k6
fi
k6 version

log "Installing kit to /opt/uvbench"
mkdir -p /opt/uvbench && cp -a "$KIT_DIR"/. /opt/uvbench/ 2>/dev/null || true

log "Creating voice clips (English + Bangla)"
bash /opt/uvbench/loadtest/make-audio.sh

mkdir -p /etc/uvbench /var/lib/uvbench/results
[ -f /etc/uvbench/loadgen.env ] || cat > /etc/uvbench/loadgen.env <<EOF
PROM_URL=http://$MON:9090
# continuous 24/7 load - set the reference target, then: systemctl enable --now uvbench-continuous uvbench-spike.timer
CONT_TIER=8c
CONT_TARGET=CHANGE_ME
CONT_PEAK_VUS=200
SPIKE_BASE_VUS=100
EOF
cp /opt/uvbench/loadtest/systemd/* /etc/systemd/system/ && systemctl daemon-reload
log "Load generator ready. Edit /etc/uvbench/loadgen.env, then run tests with:  bash /opt/uvbench/loadtest/run.sh <tier> <ip> <profile>"
