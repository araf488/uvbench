// Realistic mixed-user load. Pick a profile with PROFILE=smoke|ladder|steady|spike|soak|diurnal
//   k6 run -e BASE_URL=http://10.x.x.x -e PROFILE=ladder -e START_VUS=20 mixed.js
import { mixedUser } from './lib/actions.js';

const P = __ENV.PROFILE || 'smoke';
const VUS = parseInt(__ENV.VUS || '50', 10);
const START = parseInt(__ENV.START_VUS || '10', 10);
const STEP_PCT = parseFloat(__ENV.STEP_PCT || '10');
const STEP_MIN = parseInt(__ENV.STEP_MIN || '5', 10);
const MAX_STEPS = parseInt(__ENV.MAX_STEPS || '60', 10);
const MAX_VUS = parseInt(__ENV.MAX_VUS || '1500', 10);   // k6 pre-allocates every VU of a ramp: keep this within loadgen RAM
const DURATION = __ENV.DURATION || '30m';
const PEAK = parseInt(__ENV.PEAK_VUS || '100', 10);

function ladderStages() {            // +STEP_PCT% users every STEP_MIN minutes until the break point
  const st = []; let v = START;
  for (let i = 0; i < MAX_STEPS && Math.round(v) <= MAX_VUS; i++) {
    st.push({ duration: '30s', target: Math.round(v) }, { duration: `${STEP_MIN * 60 - 30}s`, target: Math.round(v) });
    v *= 1 + STEP_PCT / 100;
  }
  return st;
}
function diurnalStages() {           // 24 h curve as a share of PEAK_VUS (UTC hours, peak = Bangladesh/US business hours overlap)
  const curve = [0.35, 0.3, 0.3, 0.35, 0.5, 0.65, 0.8, 0.9, 0.9, 0.85, 0.8, 0.8,
                 0.85, 0.9, 0.9, 0.85, 0.75, 0.65, 0.6, 0.55, 0.5, 0.45, 0.4, 0.35];
  return curve.flatMap((f) => [{ duration: '5m', target: Math.round(PEAK * f) }, { duration: '55m', target: Math.round(PEAK * f) }]);
}

const scenarios = {
  smoke:   { executor: 'constant-vus', vus: 2, duration: '1m' },
  ladder:  { executor: 'ramping-vus', startVUs: START, stages: ladderStages(), gracefulRampDown: '30s' },
  steady:  { executor: 'constant-vus', vus: VUS, duration: DURATION },
  soak:    { executor: 'constant-vus', vus: VUS, duration: DURATION },
  spike:   { executor: 'ramping-vus', startVUs: VUS, stages: [
             { duration: '2m', target: VUS }, { duration: '10s', target: VUS * 5 }, { duration: '2m', target: VUS * 5 },
             { duration: '10s', target: VUS }, { duration: '3m', target: VUS }] },
  diurnal: { executor: 'ramping-vus', startVUs: Math.round(PEAK * 0.35), stages: diurnalStages(), gracefulRampDown: '1m' },
};
if (!scenarios[P]) throw new Error(`unknown PROFILE ${P}`);

// Pass criteria from the plan (section 5). In "ladder" mode the test stops itself at the break point.
const abort = P === 'ladder';
export const options = {
  scenarios: { users: scenarios[P] },
  discardResponseBodies: false,
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max', 'count'],
  thresholds: {
    'http_req_failed': [{ threshold: 'rate<0.01', abortOnFail: abort, delayAbortEval: '2m' }],
    'http_req_duration{kind:api}': [{ threshold: 'p(95)<800', abortOnFail: abort, delayAbortEval: '2m' }],
    'http_req_duration{kind:web}': [{ threshold: 'p(95)<800', abortOnFail: abort, delayAbortEval: '2m' }],
    'ai_first_token_ms': ['p(95)<5000'],
    'voice_round_trip_ms': ['p(95)<15000'],
  },
  tags: { tier: __ENV.TIER || 'unknown', profile: __ENV.TAGPROFILE || P },
};

export default async function () { await mixedUser(); }
