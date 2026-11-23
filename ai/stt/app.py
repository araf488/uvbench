"""Speech-to-text service: faster-whisper (CTranslate2, int8) on CPU."""
import os
import tempfile
import threading
import time

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse
from faster_whisper import WhisperModel
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, Histogram, generate_latest

MODEL = os.getenv("WHISPER_MODEL", "base")            # tiny | base | small | medium
THREADS = int(os.getenv("STT_THREADS", str(os.cpu_count() or 1)))
CONCURRENCY = int(os.getenv("STT_CONCURRENCY", "1"))  # transcriptions running at the same time
LANGUAGE = os.getenv("STT_LANGUAGE") or None          # None = auto-detect (en / bn ...)
BEAM = int(os.getenv("STT_BEAM", "1"))                # 1 = greedy (fastest)
DEVICE = os.getenv("STT_DEVICE", "cpu")               # cpu | cuda (GPU image)
COMPUTE = os.getenv("STT_COMPUTE", "int8" if DEVICE == "cpu" else "float16")

model = WhisperModel(MODEL, device=DEVICE, compute_type=COMPUTE, cpu_threads=THREADS,
                     num_workers=CONCURRENCY, download_root="/models/whisper")
slots = threading.Semaphore(CONCURRENCY)

DURATION = Histogram("stt_processing_seconds", "Transcription time", ["model"],
                     buckets=[0.1, 0.25, 0.5, 1, 2, 3, 5, 8, 13, 20, 30, 60, 120])
RTF = Histogram("stt_realtime_factor", "processing_seconds / audio_seconds", ["model"],
                buckets=[0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 4])
BUSY = Gauge("stt_busy", "Transcriptions in progress")
WAITING = Gauge("stt_waiting", "Requests waiting for a free slot")

app = FastAPI(title="uvbench-stt")


@app.get("/health")
def health():
    return {"ok": True, "model": MODEL, "device": DEVICE, "compute": COMPUTE, "threads": THREADS, "concurrency": CONCURRENCY}


@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/transcribe")
def transcribe(file: UploadFile = File(...), language: str | None = Form(None)):
    # optional per-request language hint ("bn", "en"...): skips auto-detection, which is unreliable for Bangla
    lang = (language or "").strip().lower()[:5] or LANGUAGE
    suffix = os.path.splitext(file.filename or "a.wav")[1][:6] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix) as tmp:
        tmp.write(file.file.read())
        tmp.flush()
        WAITING.inc()
        with slots:
            WAITING.dec()
            BUSY.inc()
            try:
                t0 = time.perf_counter()
                segments, info = model.transcribe(tmp.name, language=lang, beam_size=BEAM, vad_filter=True)
                text = " ".join(s.text.strip() for s in segments)  # generator: decoding happens here
                dt = time.perf_counter() - t0
            except Exception as e:  # corrupt audio etc.
                raise HTTPException(status_code=400, detail=f"cannot transcribe: {e}") from e
            finally:
                BUSY.dec()
    DURATION.labels(MODEL).observe(dt)
    if info.duration:
        RTF.labels(MODEL).observe(dt / info.duration)
    return {"text": text, "language": info.language, "duration": info.duration, "processing_seconds": round(dt, 3)}
