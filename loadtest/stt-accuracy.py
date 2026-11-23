#!/usr/bin/env python3
"""Speech-to-text accuracy check (English + Bangla). Runs on the load generator.
Synthesises short reference sentences (Piper for English, espeak-ng for Bangla), sends each clip straight to the
target's STT service and reports the character error rate (CER) per language, plus time per clip.
  python3 stt-accuracy.py <target-private-ip> [label]      e.g. python3 stt-accuracy.py 10.12.96.3 whisper-small
Note: espeak-ng Bangla is robotic, so Bangla CER is pessimistic; compare models against each other, not absolutely."""
import json, os, subprocess, sys, tempfile, time, unicodedata, urllib.request, uuid

TARGET, LABEL = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
VOICE = "/opt/piper/en_US-lessac-medium.onnx"
SENTENCES = {
    "en": ["How long does shipping take to Dhaka?",
           "I want to return a wireless headset I bought two weeks ago.",
           "Please track my order, it still says placed.",
           "Which payment methods do you accept for large orders?"],
    "bn": ["ঢাকায় ডেলিভারি পেতে কত দিন লাগবে?",
           "আমি দুই সপ্তাহ আগে একটি হেডসেট কিনেছি।",
           "আমার অর্ডারটি এখন কোথায় আছে?",
           "আপনারা কোন কোন পেমেন্ট পদ্ধতি গ্রহণ করেন?"],
}

def norm(s):
    s = unicodedata.normalize("NFC", s.lower())
    return "".join(c for c in s if c.isalnum() or c.isspace()).split()

def cer(ref, hyp):
    r, h = " ".join(norm(ref)), " ".join(norm(hyp))
    d = list(range(len(h) + 1))
    for i, rc in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hc in enumerate(h, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (rc != hc))
    return d[len(h)] / max(len(r), 1)

def synth(lang, text, path):
    if lang == "en":
        subprocess.run(["/opt/piper/bin/piper", "-m", VOICE, "-f", path], input=text.encode(), check=True, capture_output=True)
    else:
        subprocess.run(["espeak-ng", "-v", "bn", "-s", "140", "-w", path, text], check=True, capture_output=True)

def transcribe(path):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
            "Content-Type: audio/wav\r\n\r\n").encode() + open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"http://{TARGET}:8001/transcribe", data=body,
                                 headers={"content-type": f"multipart/form-data; boundary={b}"})
    t0 = time.time()
    out = json.load(urllib.request.urlopen(req, timeout=300))
    return out, time.time() - t0

health = json.load(urllib.request.urlopen(f"http://{TARGET}:8001/health", timeout=10))
print(f"== STT accuracy {LABEL}  model={health.get('model')} device={health.get('device', 'cpu')}")
summary = {}
with tempfile.TemporaryDirectory() as tmp:
    for lang, sents in SENTENCES.items():
        errs, secs, detected = [], [], []
        for i, s in enumerate(sents):
            p = os.path.join(tmp, f"{lang}{i}.wav")
            synth(lang, s, p)
            out, dt = transcribe(p)
            errs.append(cer(s, out.get("text", ""))); secs.append(dt); detected.append(out.get("language"))
            print(f"  [{lang}] CER {errs[-1]:5.1%}  {dt:4.1f}s  lang={out.get('language')}  | {out.get('text','')[:70]}")
        summary[lang] = {"cer": round(sum(errs) / len(errs), 3), "sec_per_clip": round(sum(secs) / len(secs), 2),
                         "lang_detected_ok": sum(d == lang for d in detected)}
print("SUMMARY", json.dumps({"label": LABEL, "model": health.get("model"), **summary}))
