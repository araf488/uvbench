#!/usr/bin/env bash
# Day 4: bigger-model run on the 8-core, driven from your Mac (about 2.5 hours, unattended).
#   caffeinate -i bash ~/Downloads/uvbench/scripts/day4-mac.sh 2>&1 | tee ~/Downloads/day4.log
# 1. pauses the 8c 24/7 load   2. deploys the current kit to the 8c (needed for model switching)
# 3. AI tests: standard models with 4 parallel transcriptions, then Qwen 7B + Whisper small, then Whisper medium
# 4. speech-to-text accuracy (English + Bangla) for base / small / medium
# 5. restores the standard profile and restarts the 24/7 load
set -uo pipefail
P8=149.28.194.86; I8=10.12.96.3; LG=149.28.199.74
KIT=$(cd "$(dirname "$0")/.." && pwd)
ts() { date -u +%H:%M:%SZ; }
s8() { ssh -o ServerAliveInterval=30 root@$P8 "cd /opt/uvbench && $*"; }
slg() { ssh -o ServerAliveInterval=30 root@$LG "$*"; }
ai() { slg "bash /opt/uvbench/loadtest/run.sh 8c $I8 ai -e KIND=$1 -e LEVELS=1,2,4,8 -e STEP_MIN=4 -e TAGPROFILE=$2 2>&1 | grep -E '^ *(ai_total_ms|http_req_failed)[^{]*:' | head -4"; }
acc() { slg "python3 /opt/uvbench/loadtest/stt-accuracy.py $I8 $1 2>&1 | tail -10"; }

echo "[$(ts)] 1/6 pausing 24/7 load on the 8c"
slg "systemctl stop uvbench-spike.timer uvbench-continuous; sleep 5; pgrep -af 'k6 run' | grep -c 'TIER=8c' || true"

echo "[$(ts)] 2/6 deploying current kit to the 8c and load generator"
rsync -az --exclude node_modules --exclude .next --exclude models --exclude .env "$KIT/" root@$P8:/opt/uvbench/
rsync -az "$KIT/loadtest/" root@$LG:/opt/uvbench/loadtest/
s8 "grep -q '^LLM_CACHE_RAM_MB=' .env || echo LLM_CACHE_RAM_MB=1024 >> .env
    DC='docker compose --env-file .env -f compose/docker-compose.yml'
    \$DC build -q api && \$DC up -d && sleep 20 && curl -fs http://127.0.0.1/api/health && echo"

echo "[$(ts)] 3/6 standard models, 4 transcriptions in parallel (was 2)"
s8 "STT_CONC=4 bash scripts/switch-profile.sh standard"
acc base
ai voice std-stt4
ai ask std

echo "[$(ts)] 4/6 Qwen 7B + Whisper small"
s8 "STT_CONC=4 bash scripts/switch-profile.sh max"
acc small
ai ask max-7b
ai voice max-small

echo "[$(ts)] 5/6 Qwen 7B + Whisper medium"
s8 "STT_CONC=2 bash scripts/switch-profile.sh medium"
acc medium
ai voice medium

echo "[$(ts)] 6/6 restoring standard profile and the 24/7 load"
s8 "bash scripts/switch-profile.sh standard"
slg "systemctl start uvbench-continuous uvbench-spike.timer; sleep 5; pgrep -af 'k6 run' | grep -c 'TIER=8c'"
echo "[$(ts)] Day 4 done. Paste ~/Downloads/day4.log to Claude."
