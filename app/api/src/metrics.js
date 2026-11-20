import client from 'prom-client';

export const registry = new client.Registry();
client.collectDefaultMetrics({ register: registry, prefix: 'uvbench_' });

const buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1, 2, 3, 5, 8, 15, 30, 60, 120];

export const httpDuration = new client.Histogram({
  name: 'uvbench_http_request_duration_seconds', help: 'HTTP request duration',
  labelNames: ['route', 'method', 'status'], buckets, registers: [registry],
});
export const aiStage = new client.Histogram({
  name: 'uvbench_ai_stage_seconds', help: 'Duration of AI pipeline stages',
  labelNames: ['kind', 'stage'], buckets, registers: [registry],
});
export const aiTokens = new client.Counter({
  name: 'uvbench_ai_tokens_total', help: 'LLM tokens generated', labelNames: ['kind'], registers: [registry],
});
export const aiRejected = new client.Counter({
  name: 'uvbench_ai_rejected_total', help: 'AI jobs rejected by back-pressure', labelNames: ['kind'], registers: [registry],
});
export const queueDepth = new client.Gauge({
  name: 'uvbench_queue_depth', help: 'Waiting + active jobs per queue', labelNames: ['queue', 'state'], registers: [registry],
});
export const wsClients = new client.Gauge({
  name: 'uvbench_ws_clients', help: 'Open WebSocket connections', registers: [registry],
});
export const sttRtf = new client.Histogram({
  name: 'uvbench_stt_realtime_factor', help: 'STT processing time / audio duration',
  buckets: [0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2, 4], registers: [registry],
});

export { client };
