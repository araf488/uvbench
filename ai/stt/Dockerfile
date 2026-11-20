FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN pip install faster-whisper==1.2.1 av==18.1.0 fastapi==0.165.0 uvicorn==0.54.0 python-multipart==0.0.34 prometheus-client==0.26.0
WORKDIR /srv
COPY app.py .
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--limit-concurrency", "64"]
