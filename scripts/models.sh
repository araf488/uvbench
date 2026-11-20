#!/usr/bin/env bash
# Downloads the open-source AI models into ./models (run from the kit root after .env exists).
#   bash scripts/models.sh            -> models named in .env
#   bash scripts/models.sh qwen7      -> also the 7B model for the day 15-21 "max" profile
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
HF=https://huggingface.co
declare -A URL=(
  [qwen2.5-0.5b-instruct-q4_k_m.gguf]="$HF/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"
  [qwen2.5-1.5b-instruct-q4_k_m.gguf]="$HF/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
  [Qwen2.5-7B-Instruct-Q4_K_M.gguf]="$HF/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
  [nomic-embed-text-v1.5.Q4_K_M.gguf]="$HF/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"
  [en_US-lessac-medium.onnx]="$HF/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
  [en_US-lessac-medium.onnx.json]="$HF/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
)

fetch() { # fetch <dir> <file>
  local dir="models/$1" f="$2"
  mkdir -p "$dir"
  if [ -s "$dir/$f" ]; then echo "ok      $dir/$f"; return; fi
  [ -n "${URL[$f]:-}" ] || { echo "no download URL for $f - put it in $dir manually"; exit 1; }
  echo "fetch   $dir/$f"
  curl -fL --retry 5 --retry-delay 5 -o "$dir/$f.part" "${URL[$f]}"
  mv "$dir/$f.part" "$dir/$f"
}

fetch llm   "$LLM_FILE"
fetch embed "$EMBED_FILE"
fetch piper "$PIPER_VOICE_FILE"
fetch piper "$PIPER_VOICE_FILE.json"
[ "${1:-}" = qwen7 ] && fetch llm Qwen2.5-7B-Instruct-Q4_K_M.gguf
[ "${1:-}" = lite ]  && fetch llm qwen2.5-0.5b-instruct-q4_k_m.gguf

echo "Whisper '$WHISPER_MODEL' is downloaded by the stt container on first start (into models/whisper)."
du -sh models/* 2>/dev/null
