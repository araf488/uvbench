#!/usr/bin/env bash
# Switches the AI model profile on a running target (only the AI services restart, ~20-60 s without AI answers).
#   bash scripts/switch-profile.sh max        Qwen2.5 7B + Whisper small, more parallel transcriptions
#   bash scripts/switch-profile.sh medium     Qwen2.5 7B + Whisper medium (best Bangla accuracy, slowest)
#   bash scripts/switch-profile.sh standard   back to the tier's normal models (from tiers/<tier>.env)
#   STT_CONC=4 bash scripts/switch-profile.sh standard   same models, different transcription concurrency
set -euo pipefail
cd "$(dirname "$0")/.."
P=${1:?usage: switch-profile.sh max|medium|standard}
set -a; . ./.env; set +a
setv() { grep -q "^$1=" .env && sed -i "s#^$1=.*#$1=$2#" .env || echo "$1=$2" >> .env; }
case "$P" in
  max)      setv LLM_FILE Qwen2.5-7B-Instruct-Q4_K_M.gguf; setv WHISPER_MODEL small;  bash scripts/models.sh qwen7 ;;
  medium)   setv LLM_FILE Qwen2.5-7B-Instruct-Q4_K_M.gguf; setv WHISPER_MODEL medium; bash scripts/models.sh qwen7 ;;
  standard) for k in LLM_FILE WHISPER_MODEL STT_CONCURRENCY AI_VOICE_CONCURRENCY; do setv $k "$(grep "^$k=" "tiers/$TIER.env" | cut -d= -f2)"; done ;;
  *) echo "unknown profile $P"; exit 1 ;;
esac
[ -n "${STT_CONC:-}" ] && { setv STT_CONCURRENCY "$STT_CONC"; setv AI_VOICE_CONCURRENCY "$STT_CONC"; }
set -a; . ./.env; set +a
DC="docker compose --env-file .env -f compose/docker-compose.yml${COMPOSE_EXTRA:+ -f $COMPOSE_EXTRA}"
$DC up -d llm stt worker
PIP=$PRIVATE_IP
for u in "8080/health" "8001/health"; do for i in $(seq 120); do curl -fs "http://$PIP:$u" >/dev/null && break; sleep 5; done; done
echo "profile=$P llm=$LLM_FILE whisper=$WHISPER_MODEL stt_concurrency=$STT_CONCURRENCY"
curl -fs "http://$PIP:8001/health"; echo
sed -i "s#^uvbench_tier_info{.*#uvbench_tier_info{tier=\"$TIER\",llm=\"$LLM_FILE\",whisper=\"$WHISPER_MODEL\"} 1#" /var/lib/uvbench/textfile/uvbench.prom 2>/dev/null || true
