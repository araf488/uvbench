// AI worker: consumes the ai-chat and ai-voice queues and runs the self-hosted AI pipeline.
import http from 'node:http';
import { readFile, writeFile, unlink, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Worker } from 'bullmq';
import { config } from './config.js';
import { pool } from './db.js';
import { connection, getQueues, QUEUES } from './queue.js';
import { registry, aiStage, queueDepth } from './metrics.js';
import { llmChat, embed, transcribe, synthesize, toPgVector } from './ai.js';

async function ragContext(question) {
  const [vec] = await embed([question]);
  const t0 = performance.now();
  const { rows } = await pool.query(
    'SELECT title, body FROM documents ORDER BY embedding <=> $1::vector LIMIT 3', [toPgVector(vec)]);
  aiStage.labels('rag', 'vector_search').observe((performance.now() - t0) / 1000);
  return rows.map((r) => `${r.title}: ${r.body}`).join('\n');
}

const logRequest = (kind, r) => pool.query(
  'INSERT INTO ai_requests (kind, ms_total, ms_stt, ms_llm, ms_tts, tokens_out) VALUES ($1,$2,$3,$4,$5,$6)',
  [kind, r.msTotal, r.msStt ?? null, r.msLlm ?? null, r.msTts ?? null, r.tokens ?? null]).catch(() => {});

async function chatJob(job) {
  const t0 = performance.now();
  const { type, message, question } = job.data;
  const context = type === 'ask' ? await ragContext(question) : '';
  const llm = await llmChat(type, type === 'ask' ? question : message, context);
  const msTotal = Math.round(performance.now() - t0);
  aiStage.labels(type, 'total').observe(msTotal / 1000);
  logRequest(type, { msTotal, msLlm: llm.ms, tokens: llm.tokens });
  return { answer: llm.text, tokens: llm.tokens, timings: { totalMs: msTotal, llmMs: llm.ms, firstTokenMs: llm.firstTokenMs, tokensPerSec: llm.tokensPerSec } };
}

async function voiceJob(job) {
  const t0 = performance.now();
  const inPath = path.join(config.filesDir, path.basename(job.data.file));
  try {
    const audio = await readFile(inPath);
    const stt = await transcribe(audio, path.basename(inPath));
    const transcript = (stt.text || '').trim() || '(silence)';
    const context = await ragContext(transcript);
    const llm = await llmChat('voice', transcript, context);
    const tts = await synthesize(llm.text || 'Sorry, I have no answer.');
    const outName = `out-${randomUUID()}.wav`;
    await writeFile(path.join(config.filesDir, outName), tts.wav);
    const msTotal = Math.round(performance.now() - t0);
    aiStage.labels('voice', 'total').observe(msTotal / 1000);
    logRequest('voice', { msTotal, msStt: stt.ms, msLlm: llm.ms, msTts: tts.ms, tokens: llm.tokens });
    return {
      transcript, language: stt.language, answer: llm.text, audioUrl: `/files/${outName}`,
      timings: { totalMs: msTotal, sttMs: stt.ms, audioSeconds: stt.duration, llmMs: llm.ms,
        firstTokenMs: llm.firstTokenMs, ttsMs: tts.ms },
    };
  } finally {
    unlink(inPath).catch(() => {});
  }
}

const workers = [
  new Worker(QUEUES.chat, chatJob, { connection: connection(), concurrency: config.chatConcurrency }),
  new Worker(QUEUES.voice, voiceJob, { connection: connection(), concurrency: config.voiceConcurrency }),
];
for (const w of workers) w.on('failed', (job, err) => console.error(`${w.name} job ${job?.id} failed:`, err.message));

// queue depth gauges
const { queues } = getQueues();
setInterval(async () => {
  for (const [name, q] of Object.entries(queues)) {
    const c = await q.getJobCounts('waiting', 'active', 'delayed', 'failed').catch(() => null);
    if (c) for (const [state, n] of Object.entries(c)) queueDepth.labels(name, state).set(n);
  }
}, 5000).unref();

// keep disk bounded during a 30-day run: delete generated audio older than 1 hour
setInterval(async () => {
  const cutoff = Date.now() - 3600_000;
  for (const f of await readdir(config.filesDir).catch(() => [])) {
    const p = path.join(config.filesDir, f);
    const s = await stat(p).catch(() => null);
    if (s && s.mtimeMs < cutoff) unlink(p).catch(() => {});
  }
}, 600_000).unref();

http.createServer(async (req, res) => {
  if (req.url !== '/metrics') { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': registry.contentType }).end(await registry.metrics());
}).listen(9401, '0.0.0.0');

console.log(`ai worker ${process.pid}: chat x${config.chatConcurrency}, voice x${config.voiceConcurrency}`);
const shutdown = async () => { await Promise.all(workers.map((w) => w.close())); process.exit(0); };
process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
