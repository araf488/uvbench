#!/usr/bin/env bash
# Creates the voice clips used by voice requests: English (Piper neural voice) and Bangla (espeak-ng),
# 10 / 20 / 30 s long, 16 kHz mono WAV, plus audio/clips.json. Runs on the load generator.
set -euo pipefail
cd "$(dirname "$0")"
OUT=audio; mkdir -p "$OUT"
apt-get install -y -q espeak-ng ffmpeg python3-venv >/dev/null
[ -x /opt/piper/bin/piper ] || { python3 -m venv /opt/piper && /opt/piper/bin/pip install -q piper-tts==1.8.0; }
VOICE=/opt/piper/en_US-lessac-medium.onnx
HF=https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium
[ -s "$VOICE" ] || { curl -fsSL -o "$VOICE" "$HF/en_US-lessac-medium.onnx"; curl -fsSL -o "$VOICE.json" "$HF/en_US-lessac-medium.onnx.json"; }

EN=(
 "Hello, I bought a laptop last month and the battery drains very quickly. How does the warranty work and how long will a repair take?"
 "Can you tell me how long shipping takes to Dhaka, and whether I can pick up my order from a store instead?"
 "I want to return a wireless headset that I opened two weeks ago. Is that still possible, and will I get a full refund?"
 "My router keeps disconnecting every evening. How do I update the firmware, and should I contact support before doing that?"
 "Which payment methods do you accept for orders above five hundred dollars, and can I pay in monthly installments?"
 "Please track my last order. It was placed three days ago and the status still says placed instead of shipped."
)
BN=(
 "আমি গত মাসে একটি ল্যাপটপ কিনেছি। ব্যাটারি খুব দ্রুত শেষ হয়ে যায়। ওয়ারেন্টি কীভাবে কাজ করে?"
 "ঢাকায় ডেলিভারি পেতে কত দিন লাগবে? আমি কি দোকান থেকে অর্ডার সংগ্রহ করতে পারি?"
 "আমি দুই সপ্তাহ আগে একটি হেডসেট কিনেছি। আমি কি এটি ফেরত দিতে পারি?"
 "আমার রাউটার প্রতি সন্ধ্যায় সংযোগ হারায়। ফার্মওয়্যার কীভাবে আপডেট করব?"
)

manifest="["; first=1
add() { # add <file> <lang>
  local s; s=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$1")
  [ $first = 1 ] || manifest+=","; first=0
  manifest+="{\"file\":\"$1\",\"lang\":\"$2\",\"seconds\":${s%.*}}"
}
mk() { # mk <lang> <target-seconds> <index>
  local lang=$1 target=$2 i=$3 tmp; tmp=$(mktemp -d)
  local n=0 total=0
  while [ "$total" -lt "$target" ]; do
    if [ "$lang" = en ]; then
      echo "${EN[$(( (i + n) % ${#EN[@]} ))]}" | /opt/piper/bin/piper -m "$VOICE" -f "$tmp/$n.wav" >/dev/null 2>&1
    else
      espeak-ng -v bn -s 150 -w "$tmp/$n.wav" "${BN[$(( (i + n) % ${#BN[@]} ))]}"
    fi
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/$n.wav"); total=$(( total + ${d%.*} + 1 )); n=$((n+1))
  done
  ls "$tmp"/*.wav | sort -V | sed "s/^/file '/; s/$/'/" > "$tmp/list.txt"
  ffmpeg -y -loglevel error -f concat -safe 0 -i "$tmp/list.txt" -t "$target" -ar 16000 -ac 1 "$OUT/${lang}-${target}s-$i.wav"
  rm -rf "$tmp"; add "${lang}-${target}s-$i.wav" "$lang"
}
for t in 10 20 30; do for i in 1 2; do mk en $t $i; mk bn $t $i; done; done
echo "$manifest]" > "$OUT/clips.json"
echo "Created $(ls $OUT/*.wav | wc -l) clips:"; cat "$OUT/clips.json"; echo
