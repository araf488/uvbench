const env = (k, d) => process.env[k] ?? d;
const int = (k, d) => parseInt(env(k, d), 10);

export const config = {
  port: int('PORT', '4000'),
  metricsPort: int('METRICS_PORT', '9400'),
  workers: int('API_WORKERS', '2'),               // node cluster processes in the api container
  jwtSecret: env('JWT_SECRET', 'change-me-bench-secret'),
  pg: {
    host: env('PGHOST', 'db'), user: env('PGUSER', 'bench'), password: env('PGPASSWORD', 'bench'),
    database: env('PGDATABASE', 'bench'), port: int('PGPORT', '5432'),
    max: int('PG_POOL_MAX', '10'),                 // per api process
  },
  redisUrl: env('REDIS_URL', 'redis://redis:6379'),
  llmUrl: env('LLM_URL', 'http://llm:8080'),
  embedUrl: env('EMBED_URL', 'http://embed:8080'),
  sttUrl: env('STT_URL', 'http://stt:8000'),
  ttsUrl: env('TTS_URL', 'http://tts:8000'),
  llmMaxTokens: int('LLM_MAX_TOKENS', '150'),
  aiQueueLimit: int('AI_QUEUE_LIMIT', '50'),       // back-pressure: reject AI jobs beyond this backlog (HTTP 503)
  aiTimeoutMs: int('AI_TIMEOUT_MS', '120000'),
  chatConcurrency: int('AI_CHAT_CONCURRENCY', '2'),
  voiceConcurrency: int('AI_VOICE_CONCURRENCY', '1'),
  filesDir: env('FILES_DIR', '/data/files'),
  tier: env('TIER', 'unknown'),
};
