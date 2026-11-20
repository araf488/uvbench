// Clients for the self-hosted AI services. All calls go over the internal Docker network.
import { config } from './config.js';
import { aiStage, aiTokens, sttRtf } from './metrics.js';

const SYSTEM_PROMPT =
  'You are the helpful assistant of an electronics store. Answer briefly (max 3 sentences) using the context if relevant.';

async function postJson(url, body, timeoutMs = config.aiTimeoutMs) {
  const res = await fetch(url, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) throw new Error(`${url} -> ${res.status} ${await res.text().catch(() => '')}`);
  return res.json();
}

/** Chat completion via llama.cpp's OpenAI-compatible server. */
export async function llmChat(kind, userText, context = '') {
  const t0 = performance.now();
  const messages = [{ role: 'system', content: SYSTEM_PROMPT }];
  if (context) messages.push({ role: 'system', content: `Context:\n${context}` });
  messages.push({ role: 'user', content: userText });
  const out = await postJson(`${config.llmUrl}/v1/chat/completions`, {
    messages, max_tokens: config.llmMaxTokens, temperature: 0.7, stream: false,
  });
  const ms = performance.now() - t0;
  const text = out.choices?.[0]?.message?.content ?? '';
  const tokens = out.usage?.completion_tokens ?? 0;
  // llama.cpp returns its own timings: prompt_ms ~ time to first token, predicted_per_second ~ generation speed
  const t = out.timings ?? {};
  aiStage.labels(kind, 'llm').observe(ms / 1000);
  if (t.prompt_ms != null) aiStage.labels(kind, 'llm_first_token').observe(t.prompt_ms / 1000);
  aiTokens.labels(kind).inc(tokens);
  return { text, tokens, ms: Math.round(ms), firstTokenMs: t.prompt_ms ?? null, tokensPerSec: t.predicted_per_second ?? null };
}

export async function embed(texts) {
  const t0 = performance.now();
  const out = await postJson(`${config.embedUrl}/v1/embeddings`, {
    input: texts.map((t) => `search_query: ${t}`),
  });
  aiStage.labels('rag', 'embed').observe((performance.now() - t0) / 1000);
  return out.data.map((d) => d.embedding);
}

export async function embedDocuments(texts) {
  const out = await postJson(`${config.embedUrl}/v1/embeddings`, {
    input: texts.map((t) => `search_document: ${t}`),
  });
  return out.data.map((d) => d.embedding);
}

/** Speech to text. audio = Buffer (wav/mp3/ogg/webm). */
export async function transcribe(audio, filename = 'audio.wav') {
  const t0 = performance.now();
  const form = new FormData();
  form.append('file', new Blob([audio]), filename);
  const res = await fetch(`${config.sttUrl}/transcribe`, {
    method: 'POST', body: form, signal: AbortSignal.timeout(config.aiTimeoutMs),
  });
  if (!res.ok) throw new Error(`stt -> ${res.status}`);
  const out = await res.json();
  const ms = performance.now() - t0;
  aiStage.labels('voice', 'stt').observe(ms / 1000);
  if (out.duration > 0) sttRtf.observe(out.processing_seconds / out.duration);
  return { ...out, ms: Math.round(ms) };
}

/** Text to speech, returns WAV bytes. */
export async function synthesize(text) {
  const t0 = performance.now();
  const res = await fetch(`${config.ttsUrl}/synthesize`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text }), signal: AbortSignal.timeout(config.aiTimeoutMs),
  });
  if (!res.ok) throw new Error(`tts -> ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const ms = performance.now() - t0;
  aiStage.labels('voice', 'tts').observe(ms / 1000);
  return { wav: buf, ms: Math.round(ms) };
}

export const toPgVector = (v) => `[${v.join(',')}]`;
