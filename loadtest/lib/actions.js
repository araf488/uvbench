// User actions for the UVBench reference app. Each call = one user action with realistic think time.
import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

export const BASE = __ENV.BASE_URL || 'http://127.0.0.1';
const N_PRODUCTS = parseInt(__ENV.N_PRODUCTS || '1000000', 10);
const N_USERS = parseInt(__ENV.N_USERS || '100000', 10);
const AUDIO_DIR = __ENV.AUDIO_DIR || '../audio';

export const aiTotal = new Trend('ai_total_ms', true);
export const aiFirstToken = new Trend('ai_first_token_ms', true);
export const voiceRoundTrip = new Trend('voice_round_trip_ms', true);
export const sttMs = new Trend('stt_ms', true);
export const aiRejected = new Counter('ai_rejected');
export const wsMessages = new Counter('ws_messages_received');

// ---- audio clips for voice requests (created by loadtest/make-audio.sh) ----
let clips = [];
try {
  clips = JSON.parse(open(`${AUDIO_DIR}/clips.json`)).map((c) => ({ ...c, data: open(`${AUDIO_DIR}/${c.file}`, 'b') }));
} catch (_) { /* voice actions are skipped when no clips exist */ }

const rand = (n) => 1 + Math.floor(Math.random() * n);
const pick = (a) => a[Math.floor(Math.random() * a.length)];
const think = () => sleep(1 + Math.random() * 2);
const ok = (res, name) => check(res, { [`${name} ok`]: (r) => r.status >= 200 && r.status < 400 });

const WORDS = ['laptop', 'phone', 'wireless', 'camera', 'speaker', 'watch', 'portable', 'monitor', 'router', 'gaming'];
const QUESTIONS = [
  'How does the laptop warranty work?', 'Can I return a headset after two weeks?', 'How long does shipping take?',
  'How do I update my router firmware?', 'What payment methods do you accept?', 'How do I track my order?',
  'Is there a repair service for cameras?', 'How should I care for my watch battery?',
];

// ---------- browsing (Next.js SSR) ----------
export function browseHome() { ok(http.get(`${BASE}/`, { tags: { name: 'web_home', kind: 'web' } }), 'home'); think(); }
export function browseList() {
  ok(http.get(`${BASE}/products?page=${rand(200)}`, { tags: { name: 'web_products', kind: 'web' } }), 'list'); think();
}
export function browseProduct() {
  ok(http.get(`${BASE}/products/${rand(N_PRODUCTS)}`, { tags: { name: 'web_product', kind: 'web' } }), 'product'); think();
}
export function search() {
  ok(http.get(`${BASE}/search?q=${pick(WORDS)}`, { tags: { name: 'web_search', kind: 'web' } }), 'search'); think();
}

// ---------- authenticated writes (API) ----------
let token = null;
function login() {
  const res = http.post(`${BASE}/api/auth/login`, JSON.stringify({ email: `user${rand(N_USERS)}@bench.test`, password: 'bench-pass' }),
    { headers: { 'content-type': 'application/json' }, tags: { name: 'api_login', kind: 'api' } });
  ok(res, 'login');
  token = res.status === 200 ? res.json('token') : null;
}
const authHeaders = () => ({ 'content-type': 'application/json', authorization: `Bearer ${token}` });

export function placeOrder() {
  if (!token) login();
  const items = Array.from({ length: rand(3) }, () => ({ productId: rand(N_PRODUCTS), qty: rand(2) }));
  const res = http.post(`${BASE}/api/orders`, JSON.stringify({ items }), { headers: authHeaders(), tags: { name: 'api_order', kind: 'api' } });
  if (res.status === 401) token = null;
  ok(res, 'order'); think();
}
export function myOrders() {
  if (!token) login();
  ok(http.get(`${BASE}/api/orders/me`, { headers: authHeaders(), tags: { name: 'api_my_orders', kind: 'api' } }), 'my orders'); think();
}

// ---------- real-time chat (WebSocket) ----------
export function chatSession() {
  const wsBase = BASE.replace(/^http/, 'ws');
  const res = ws.connect(`${wsBase}/ws/chat?room=room${rand(50)}`, { tags: { name: 'ws_chat', kind: 'ws' } }, (socket) => {
    socket.on('open', () => {
      let sent = 0;
      socket.setInterval(() => { socket.send(`hello ${sent++} from vu ${__VU}`); if (sent >= 3) socket.close(); }, 3000);
    });
    socket.on('message', () => wsMessages.add(1));
    socket.setTimeout(() => socket.close(), 15000);
  });
  check(res, { 'ws connected': (r) => r && r.status === 101 });
}

// ---------- AI (self-hosted) ----------
function recordAi(res, name) {
  if (res.status === 503) { aiRejected.add(1, { name }); return; }
  ok(res, name);
  if (res.status === 200) {
    const t = res.json('timings') || {};
    aiTotal.add(t.totalMs ?? res.timings.duration, { name });
    if (t.firstTokenMs != null) aiFirstToken.add(t.firstTokenMs, { name });
    if (t.sttMs != null) sttMs.add(t.sttMs, { name });
  }
}
const aiParams = (name) => ({ headers: { 'content-type': 'application/json' }, tags: { name, kind: 'ai' }, timeout: '180s' });

export function aiChat() {
  recordAi(http.post(`${BASE}/api/ai/chat`, JSON.stringify({ message: pick(QUESTIONS) }), aiParams('ai_chat')), 'ai_chat'); think();
}
export function aiAsk() {
  recordAi(http.post(`${BASE}/api/ai/ask`, JSON.stringify({ question: pick(QUESTIONS) }), aiParams('ai_ask')), 'ai_ask'); think();
}
export function voice() {
  if (!clips.length) { aiAsk(); return; }
  const c = pick(clips);
  const res = http.post(`${BASE}/api/ai/voice`, { file: http.file(c.data, c.file, 'audio/wav') },
    { tags: { name: 'ai_voice', kind: 'ai', lang: c.lang }, timeout: '180s' });
  recordAi(res, 'ai_voice');
  if (res.status === 200) voiceRoundTrip.add(res.timings.duration, { lang: c.lang });
  think();
}

// ---------- weighted realistic user mix (plan section 4) ----------
const MIX = [
  [15, browseHome], [15, browseList], [20, browseProduct], [10, search],   // 60% browse
  [15, placeOrder], [5, myOrders],                                          // 20% write
  [10, chatSession],                                                        // 10% real-time chat
  [4, aiAsk], [3, aiChat],                                                  //  7% AI chat
  [3, voice],                                                               //  3% voice
];
const TOTAL = MIX.reduce((s, [w]) => s + w, 0);
export function mixedUser() {
  let r = Math.random() * TOTAL;
  for (const [w, fn] of MIX) { if ((r -= w) < 0) return fn(); }
}
