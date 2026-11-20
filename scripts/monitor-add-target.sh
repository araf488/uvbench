#!/usr/bin/env bash
# Registers a tested server with Prometheus (on the monitoring server).
#   bash scripts/monitor-add-target.sh 8c 10.1.96.3        add / update
#   bash scripts/monitor-add-target.sh 8c --remove           remove after the tier window ends
set -euo pipefail
cd "$(dirname "$0")/../monitoring/prometheus"
TIER=${1:?tier}; IP=${2:?private ip or --remove}
mkdir -p targets
if [ "$IP" = --remove ]; then rm -f targets/"$TIER"-*.json; echo "removed $TIER"; exit 0; fi
declare -A PORT=([node]=9100 [cadvisor]=8088 [postgres]=9187 [redis]=9121 [nginx]=9113 [api]=9400 [worker]=9401 [llm]=8080 [embed]=8082 [stt]=8001 [tts]=8003)
for job in "${!PORT[@]}"; do
  printf '[{"targets":["%s:%s"],"labels":{"tier":"%s"}}]\n' "$IP" "${PORT[$job]}" "$TIER" > "targets/$TIER-$job.json"
done
echo "Prometheus now scrapes tier $TIER at $IP (file_sd reloads within ~1 minute)"
