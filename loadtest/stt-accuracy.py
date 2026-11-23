#!/usr/bin/env python3
"""Speech-to-text accuracy check (English + Bangla). Runs on the load generator.
Synthesises short reference sentences (Piper for English, espeak-ng for Bangla), sends each clip straight to the
target's STT service and reports the character error rate (CER) per language, plus time per clip.
  python3 stt-accuracy.py <target-private-ip> [label]      e.g. python3 stt-accuracy.py 10.12.96.3 whisper-small
Each language runs twice: auto-detect, and with the language given ("forced"), as the app does with ?lang=bn.
Real recordings: put clips in loadtest/clips/<lang>/<name>.(wav|m4a|mp3|ogg) with the exact sentence in <name>.txt;
when that folder has clips they are used instead of synthetic speech.
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

def transcribe(path, lang=None):
    b = uuid.uuid4().hex
    hint = (f"--{b}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n{lang}\r\n").encode() if lang else b""
    body = hint + (f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{os.path.basename(path)}\"\r\n"
            "Content-Type: audio/wav\r\n\r\n").encode() + open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"http://{TARGET}:8001/transcribe", data=body,
                                 headers={"content-type": f"multipart/form-data; boundary={b}"})
    t0 = time.time()
    out = json.load(urllib.request.urlopen(req, timeout=300))
    return out, time.time() - t0

health = json.load(urllib.request.urlopen(f"http://{TARGET}:8001/health", timeout=10))
print(f"== STT accuracy {LABEL}  model={health.get('model')} device={health.get('device', 'cpu')}")
CLIPS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clips")
AUDIO_EXT = (".wav", ".m4a", ".mp3", ".ogg", ".webm")

def items(lang, tmp):
    d = os.path.join(CLIPS, lang)
    real = sorted(f for f in os.listdir(d) if f.lower().endswith(AUDIO_EXT)) if os.path.isdir(d) else []
    if real:
        for f in real:
            txt = os.path.join(d, os.path.splitext(f)[0] + ".txt")
            if os.path.exists(txt):
                yield os.path.join(d, f), open(txt, encoding="utf-8").read().strip(), "recorded"
        return
    for i, s in enumerate(SENTENCES[lang]):
        p = os.path.join(tmp, f"{lang}{i}.wav")
        synth(lang, s, p)
        yield p, s, "synthetic"

summary = {}
with tempfile.TemporaryDirectory() as tmp:
    for lang in SENTENCES:
        clips = list(items(lang, tmp))
        for mode in ("auto", "forced"):
            errs, secs, detected = [], [], []
            for p, s, src in clips:
                out, dt = transcribe(p, lang if mode == "forced" else None)
                errs.append(cer(s, out.get("text", ""))); secs.append(dt); detected.append(out.get("language"))
                print(f"  [{lang} {mode} {src}] CER {errs[-1]:5.1%}  {dt:4.1f}s  lang={out.get('language')}  | {out.get('text','')[:70]}")
            if errs:
                summary[f"{lang}_{mode}"] = {"cer": round(sum(errs) / len(errs), 3), "sec_per_clip": round(sum(secs) / len(secs), 2),
                                             "lang_detected_ok": sum(d == lang for d in detected), "clips": len(errs), "source": clips[0][2]}
print("SUMMARY", json.dumps({"label": LABEL, "model": health.get("model"), **summary}))
