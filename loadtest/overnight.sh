#!/usr/bin/env bash
# Unattended test chain for one tier. Runs on the load generator:
#   nohup bash /opt/uvbench/loadtest/overnight.sh 8c 10.12.96.3 > /root/overnight.log 2>&1 &
# 1. waits for any k6 test already running (e.g. the mixed ladder)
# 2. web/API-only ladder (AI off)            -> non-AI break point
# 3. AI-only concurrency: ask, then voice      -> AI throughput per concurrency
# 4. reference tier (8c): starts 24/7 continuous diurnal load at 70% of the mixed break point (+ spike timer)
#    other tiers: 24 h soak at 70% of their mixed break point (the 24/7 load on 8c keeps running alongside)
set -uo pipefail
TIER=${1:?tier}; TARGET=${2:?target private ip}
R=/opt/uvbench/loadtest/run.sh
RES=/var/lib/uvbench/results/$TIER
ts() { date -u +%FT%TZ; }
latest() { ls -t "$RES"/*-"$1".json 2>/dev/null | head -1; }
maxvus() { jq -r '.metrics.vus.max // .metrics.vus_max.max // 0' "$1" 2>/dev/null; }

echo "[$(ts)] overnight chain for $TIER ($TARGET)"
# wait only for tests aimed at THIS target (the 24/7 load on another tier may run forever)
while pgrep -af "k6 run" | grep -q "BASE_URL=http://$TARGET "; do sleep 60; done
echo "[$(ts)] no k6 running, starting chain"

if [ -z "$(latest ladder)" ]; then
  echo "[$(ts)] mixed ladder (realistic mix incl. AI)"
  bash $R "$TIER" "$TARGET" ladder -e START_VUS=${START_VUS:-5} -e MAX_VUS=1500 >/dev/null 2>&1
fi
MIXED_JSON=$(latest ladder)
MIXED_BREAK=$( [ -n "$MIXED_JSON" ] && maxvus "$MIXED_JSON" || echo 0 )
echo "[$(ts)] mixed ladder break point: ${MIXED_BREAK} VUs ($MIXED_JSON)"

echo "[$(ts)] web/API-only ladder (AI_WEIGHT=0)"
bash $R "$TIER" "$TARGET" ladder -e AI_WEIGHT=0 -e START_VUS=50 -e MAX_VUS=1500 >/dev/null 2>&1
echo "[$(ts)] web-only break point: $(maxvus "$(latest ladder)") VUs ($(latest ladder))"

for kind in ask voice; do
  echo "[$(ts)] AI-only: $kind at 1,2,4,8 concurrent"
  bash $R "$TIER" "$TARGET" ai -e KIND=$kind -e LEVELS=1,2,4,8 -e STEP_MIN=5 >/dev/null 2>&1
done

PEAK=$(( MIXED_BREAK * 70 / 100 )); [ "$PEAK" -lt 10 ] && PEAK=10
if [ "$TIER" != "${REFERENCE_TIER:-8c}" ]; then
  echo "[$(ts)] 24 h soak on $TIER at $PEAK VUs (70% of $MIXED_BREAK)"
  bash $R "$TIER" "$TARGET" soak -e VUS=$PEAK -e DURATION=24h >/dev/null 2>&1
  echo "[$(ts)] chain done"; exit 0
fi
SPIKE=$(( PEAK / 2 )); [ "$SPIKE" -lt 5 ] && SPIKE=5
mkdir -p /etc/uvbench
touch /etc/uvbench/loadgen.env
for kv in "CONT_TIER=$TIER" "CONT_TARGET=$TARGET" "CONT_PEAK_VUS=$PEAK" "SPIKE_BASE_VUS=$SPIKE"; do
  k=${kv%%=*}; grep -q "^$k=" /etc/uvbench/loadgen.env && sed -i "s#^$k=.*#$kv#" /etc/uvbench/loadgen.env || echo "$kv" >> /etc/uvbench/loadgen.env
done
systemctl daemon-reload
systemctl enable --now uvbench-continuous.service uvbench-spike.timer
echo "[$(ts)] 24/7 continuous load started: diurnal peak $PEAK VUs (70% of $MIXED_BREAK), spikes every 6 h from $SPIKE VUs"
echo "[$(ts)] chain done"
