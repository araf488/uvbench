"""Text-to-speech service: Piper (ONNX) on CPU. Returns a WAV file."""
import io
import os
import threading
import time
import wave

from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse, Response
from piper import PiperVoice
from prometheus_client import CONTENT_TYPE_LATEST, Histogram, generate_latest
from pydantic import BaseModel

VOICE = os.getenv("PIPER_VOICE", "/models/piper/en_US-lessac-medium.onnx")
CONCURRENCY = int(os.getenv("TTS_CONCURRENCY", "1"))

voice = PiperVoice.load(VOICE)
slots = threading.Semaphore(CONCURRENCY)
DURATION = Histogram("tts_processing_seconds", "Synthesis time",
                     buckets=[0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5, 8, 13, 20])

app = FastAPI(title="uvbench-tts")


class Req(BaseModel):
    text: str


@app.get("/health")
def health():
    return {"ok": True, "voice": os.path.basename(VOICE)}


@app.get("/metrics")
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/synthesize")
def synthesize(req: Req):
    text = req.text.strip()[:1000]
    if not text:
        raise HTTPException(status_code=400, detail="text required")
    buf = io.BytesIO()
    with slots:
        t0 = time.perf_counter()
        with wave.open(buf, "wb") as wf:
            voice.synthesize_wav(text, wf)
        DURATION.observe(time.perf_counter() - t0)
    return Response(content=buf.getvalue(), media_type="audio/wav")
