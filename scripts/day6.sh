#!/usr/bin/env bash
# Day 6: GPU server (NVIDIA A16). Runs ON THE LOAD GENERATOR, unattended, about 4.5 hours, then leaves a soak running.
#   systemd-run --unit uvbench-day6 --collect bash -c "cd /opt/uvbench && bash scripts/day6.sh <gpu-public-ip> > /root/day6.log 2>&1"
#  1. GPU driver + container toolkit, full app setup (gpu tier)     2. speech-to-text accuracy + speed, English + Bangla
#     for Whisper base / small / medium / large-v3 / large-v3-turbo / a Bangla fine-tuned model (your recordings)
#  3. AI capacity: Qwen 1.5B and Qwen 7B, typed + voice, 1 -> 16 at once   4. Bangla typed chat samples (1.5B vs 7B)
#  5. mixed users ladder (compare 1x8c ~50, 2x4c ~75)   6. starts a steady soak until the Day 7 cut-off
# The 8c 24/7 load keeps running (AI tests put little load on the load generator).
set -uo pipefail
PG=${1:?usage: day6.sh <gpu-public-ip>}; MON=45.77.187.211
SSH="ssh -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
DCG='docker compose --env-file .env -f compose/docker-compose.yml -f compose/docker-compose.gpu.yml'
ts() { date -u +%H:%M:%SZ; }
ev() { echo "[$(ts)] EVENT $*"; }
on() { local h=$1; shift; $SSH root@$h "cd /opt/uvbench && $*"; }
R=/opt/uvbench/loadtest/run.sh
ai() { bash $R gpu $IG ai -e KIND=$1 -e LEVELS=1,2,4,8,16 -e STEP_MIN=4 -e TAGPROFILE=$2 2>&1 | grep -E '^\s*(ai_total_ms|http_req_failed)[^{]*:' | head -2; }
setstt() {   # setstt <model> [beam]
  on $PG "sed -i '/^WHISPER_MODEL=/d; /^STT_BEAM=/d' .env; echo 'WHISPER_MODEL=$1' >> .env; echo 'STT_BEAM=${2:-1}' >> .env
          $DCG up -d stt >/dev/null 2>&1; $DCG restart nginx >/dev/null 2>&1
          for i in \$(seq 120); do curl -fs http://$IG:8001/health >/dev/null 2>&1 && break; sleep 5; done; curl -s http://$IG:8001/health; echo"
}

echo "[$(ts)] 1/6 preparing the GPU server"
until $SSH -o ConnectTimeout=5 root@$PG true 2>/dev/null; do echo "  waiting for ssh..."; sleep 15; done
rsync -az -e "$SSH" --exclude node_modules --exclude .next --exclude models --exclude .env --exclude 'loadtest/clips/' /opt/uvbench/ root@$PG:/opt/uvbench/
on $PG "bash scripts/gpu-prepare.sh 2>&1 | tail -8"
if ! on $PG "nvidia-smi -L"; then
  echo "[$(ts)] rebooting once for the NVIDIA driver"; on $PG "reboot" >/dev/null 2>&1 || true; sleep 90
  until $SSH -o ConnectTimeout=5 root@$PG true 2>/dev/null; do sleep 15; done
  on $PG "bash scripts/gpu-prepare.sh 2>&1 | tail -8"; on $PG "nvidia-smi -L" || { echo "[$(ts)] ERROR: no usable GPU driver - stopping"; exit 1; }
fi
on $PG "bash scripts/bootstrap-target.sh gpu 2>&1 | grep -vE 'Pulling|Downloading|Extracting|Waiting|Verifying|#[0-9]+ |Building|Built' | tail -25"
IG=$(on $PG "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -E '^10\.' | head -1")
echo "  GPU private IP: $IG"
on $MON "bash scripts/monitor-add-target.sh gpu $IG"
on $PG "nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader; bash scripts/hwbench.sh 2>&1 | tail -6"
# GPU utilisation log for the report (every 5 s)
on $PG "pkill -f '[n]vidia-smi --query-gpu=timestamp'; nohup nvidia-smi --query-gpu=timestamp,utilization.gpu,memory.used --format=csv,noheader -l 5 > /root/gpu-util.csv 2>&1 < /dev/null &"

echo "[$(ts)] 2/6 speech-to-text accuracy (English synthetic + your Bangla recordings)"
for m in base small medium large-v3 large-v3-turbo SayedShaun/bengali-whisper-medium-ct2; do
  echo "--- $m"; setstt $m
  python3 /opt/uvbench/loadtest/stt-accuracy.py $IG $m 2>&1 | grep -E '^\s+\[bn|SUMMARY|Error|error' | tail -9
done
echo "--- large-v3, beam 5 (slower, more careful decoding)"; setstt large-v3 5
python3 /opt/uvbench/loadtest/stt-accuracy.py $IG large-v3-beam5 2>&1 | grep -E '^\s+\[bn|SUMMARY' | tail -9
echo "--- Bangla fine-tuned, beam 5"; setstt SayedShaun/bengali-whisper-medium-ct2 5
python3 /opt/uvbench/loadtest/stt-accuracy.py $IG bn-medium-beam5 2>&1 | grep -E '^\s+\[bn|SUMMARY' | tail -9
setstt base

echo "[$(ts)] 3/6 AI capacity on the GPU (each: 1, 2, 4, 8, 16 at once, 4 min per level)"
ev "gpu ai standard (Qwen 1.5B, Whisper base)"
ai ask gpu-std; ai voice gpu-std
on $PG "bash scripts/switch-profile.sh max | grep profile="
ev "gpu ai max (Qwen 7B, Whisper small)"
ai ask gpu-7b; ai voice gpu-7b-small
setstt large-v3-turbo
ev "gpu ai voice (Qwen 7B, Whisper large-v3-turbo)"
ai voice gpu-7b-turbo

echo "[$(ts)] 4/6 Bangla typed chat, Qwen 7B then Qwen 1.5B (answers shortened)"
bn_chat() {
  python3 - "$IG" <<'PY'
import json, sys, urllib.request
ip = sys.argv[1]
for q in ["ঢাকায় ডেলিভারি পেতে কত দিন লাগবে?", "আমি একটি হেডসেট ফেরত দিতে চাই। কীভাবে করব?", "আপনারা কোন কোন পেমেন্ট পদ্ধতি গ্রহণ করেন?"]:
    body = json.dumps({"messages": [{"role": "system", "content": "You are a helpful shop assistant. Answer in Bangla."},
                                    {"role": "user", "content": q}], "max_tokens": 120, "temperature": 0.2}).encode()
    r = json.load(urllib.request.urlopen(urllib.request.Request(f"http://{ip}:8080/v1/chat/completions", data=body,
                  headers={"content-type": "application/json"}), timeout=120))
    print("  Q:", q); print("  A:", r["choices"][0]["message"]["content"].replace("\n", " ")[:300])
PY
}
echo "--- Qwen 7B"; bn_chat
on $PG "bash scripts/switch-profile.sh standard | grep profile="
echo "--- Qwen 1.5B"; bn_chat

echo "[$(ts)] 5/6 mixed users ladder on the GPU server (standard models)"
ev "gpu mixed ladder start"
bash $R gpu $IG ladder -e START_VUS=40 -e TAGPROFILE=gpu-mixed-ladder 2>&1 | grep -E '^\s*(http_req_failed|http_reqs|vus_max)[ .:]' | head -3
ev "gpu mixed ladder end"
echo "GPU use during the tests (avg / max %):"
on $PG "awk -F', ' '{gsub(/ %/,\"\",\$2); s+=\$2; n++; if (\$2>m) m=\$2} END {printf \"  %.0f / %.0f  (%d samples)\n\", s/n, m, n}' /root/gpu-util.csv"

echo "[$(ts)] 6/6 steady soak on the GPU server: 40 mixed users, 18 h (until the Day 7 cut-off; keeps the GPU day within budget)"
systemd-run --unit uvbench-gpu-soak --collect bash $R gpu $IG soak -e VUS=40 -e DURATION=18h -e TAGPROFILE=gpu-soak >/dev/null
echo "[$(ts)] Day 6 done."
