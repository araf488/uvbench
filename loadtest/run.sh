#!/usr/bin/env bash
# Wrapper used by humans and by the systemd units. Streams metrics to Prometheus and keeps a JSON summary.
#   bash run.sh <tier> <target-private-ip> <profile> [extra k6 -e flags...]
#   bash run.sh 8c 10.1.96.3 ladder -e START_VUS=50
#   bash run.sh 8c 10.1.96.3 ai -e KIND=voice
set -euo pipefail
cd "$(dirname "$0")"
TIER=${1:?tier}; TARGET=${2:?target private ip}; PROFILE=${3:?profile}; shift 3
[ -f /etc/uvbench/loadgen.env ] && . /etc/uvbench/loadgen.env      # PROM_URL=http://<monitor-ip>:9090
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR=/var/lib/uvbench/results/$TIER; mkdir -p "$OUTDIR"
SCRIPT=mixed.js; [ "$PROFILE" = ai ] && SCRIPT=ai.js

OUTPUTS=()
if [ -n "${PROM_URL:-}" ]; then
  export K6_PROMETHEUS_RW_SERVER_URL="$PROM_URL/api/v1/write"
  export K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),avg,max"
  OUTPUTS=(-o experimental-prometheus-rw)
fi
ulimit -n 1000000 || true
echo "[$STAMP] $TIER $PROFILE -> $TARGET $*"
k6 run "${OUTPUTS[@]}" --summary-export "$OUTDIR/$STAMP-$PROFILE.json" \
  -e BASE_URL="http://$TARGET" -e TIER="$TIER" -e PROFILE="$PROFILE" -e AUDIO_DIR="$PWD/audio" "$@" "$SCRIPT" \
  2>&1 | tee "$OUTDIR/$STAMP-$PROFILE.log" | grep -vE '^\s*(running|default|users)\b' || true
echo "summary: $OUTDIR/$STAMP-$PROFILE.json"
