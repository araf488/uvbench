// AI-only capacity test: 1 -> 2 -> 4 -> 8 -> 16 concurrent requests of one kind, 5 min each.
//   k6 run -e BASE_URL=http://10.x.x.x -e KIND=voice ai.js        (KIND = chat | ask | voice)
import { aiChat, aiAsk, voice } from './lib/actions.js';

const KIND = __ENV.KIND || 'ask';
const LEVELS = (__ENV.LEVELS || '1,2,4,8,16').split(',').map(Number);
const STEP_MIN = parseInt(__ENV.STEP_MIN || '5', 10);
const fn = { chat: aiChat, ask: aiAsk, voice }[KIND];
if (!fn) throw new Error(`unknown KIND ${KIND}`);

export const options = {
  scenarios: Object.fromEntries(LEVELS.map((n, i) => [`c${n}`, {
    executor: 'constant-vus', vus: n, duration: `${STEP_MIN}m`, startTime: `${i * STEP_MIN}m`, tags: { concurrency: String(n) },
  }])),
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'max', 'count'],
  thresholds: Object.fromEntries(LEVELS.flatMap((n) => [
    [`ai_total_ms{concurrency:${n}}`, ['p(95)<60000']],
    [`http_reqs{concurrency:${n}}`, ['count>=0']],
  ])),
  tags: { tier: __ENV.TIER || 'unknown', profile: `ai-${KIND}` },
};

export default function () { fn(); }
