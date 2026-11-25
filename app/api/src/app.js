import { createHash, randomUUID } from 'node:crypto';
import path from 'node:path';
import Fastify from 'fastify';
import jwt from '@fastify/jwt';
import multipart from '@fastify/multipart';
import websocket from '@fastify/websocket';
import IORedis from 'ioredis';
import { config } from './config.js';
import { pool } from './db.js';
import { httpDuration, wsClients, aiRejected } from './metrics.js';
import { runAiJob } from './queue.js';

const sha256 = (s) => createHash('sha256').update(s).digest('hex');
const clampInt = (v, d, min, max) => Math.min(max, Math.max(min, parseInt(v ?? d, 10) || d));

export async function buildApp() {
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'warn' }, trustProxy: true, bodyLimit: 1_048_576 });
  await app.register(jwt, { secret: config.jwtSecret, sign: { expiresIn: '12h' } });
  await app.register(multipart, { limits: { fileSize: 10 * 1024 * 1024, files: 1 } });
  await app.register(websocket);

  // ---- metrics on every response ----
  app.addHook('onResponse', async (req, reply) => {
    const route = req.routeOptions?.url ?? 'unmatched';
    httpDuration.labels(route, req.method, String(reply.statusCode)).observe(reply.elapsedTime / 1000);
  });

  const auth = async (req) => { await req.jwtVerify(); };

  // ---- health ----
  app.get('/health', async () => {
    await pool.query('SELECT 1');
    return { ok: true, tier: config.tier, pid: process.pid };
  });

  // ---- auth ----
  app.post('/auth/login', async (req, reply) => {
    const { email, password } = req.body ?? {};
    if (!email || !password) return reply.code(400).send({ error: 'email and password required' });
    const { rows } = await pool.query('SELECT id, name, pw_hash FROM users WHERE email = $1', [email]);
    if (!rows[0] || rows[0].pw_hash !== sha256(password)) return reply.code(401).send({ error: 'invalid login' });
    return { token: app.jwt.sign({ sub: rows[0].id, name: rows[0].name }) };
  });

  // ---- catalogue (read-heavy) ----
  app.get('/products', async (req) => {
    const limit = clampInt(req.query.limit, 20, 1, 50);
    const page = clampInt(req.query.page, 1, 1, 500);
    const params = [limit, (page - 1) * limit];
    let where = '';
    if (req.query.category) { params.push(req.query.category); where = 'WHERE category = $3'; }
    const { rows } = await pool.query(
      `SELECT id, sku, name, category, price_cents, stock, rating FROM products ${where}
       ORDER BY id LIMIT $1 OFFSET $2`, params);
    return { page, items: rows };
  });

  app.get('/products/:id', async (req, reply) => {
    const { rows } = await pool.query('SELECT * FROM products WHERE id = $1', [req.params.id]);
    if (!rows[0]) return reply.code(404).send({ error: 'not found' });
    const { search, ...product } = rows[0];
    return product;
  });

  app.get('/search', async (req, reply) => {
    const q = String(req.query.q ?? '').slice(0, 100);
    if (!q) return { items: [] };
    // Day 5 finding: a search scans and sorts every matching product (~66 ms, ~100k rows) and was ~all of the
    // database CPU. Results are cached in Redis (shared by every node) for SEARCH_CACHE_SEC seconds; 0 = off.
    const ttl = config.searchCacheSec;
    const key = `search:${q.toLowerCase().trim()}`;
    if (ttl > 0) {
      const hit = await pub.get(key).catch(() => null);
      if (hit) { reply.header('x-cache', 'hit'); return JSON.parse(hit); }
    }
    const { rows } = await pool.query(
      `SELECT id, name, category, price_cents, rating FROM products
       WHERE search @@ plainto_tsquery('english', $1) ORDER BY rating DESC, id LIMIT 20`, [q]);
    const body = { items: rows };
    if (ttl > 0) pub.set(key, JSON.stringify(body), 'EX', ttl).catch(() => {});
    return body;
  });

  // ---- orders (write, transactional) ----
  app.post('/orders', { preHandler: auth }, async (req, reply) => {
    const items = (req.body?.items ?? []).slice(0, 5);
    if (!items.length) return reply.code(400).send({ error: 'items required' });
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      let total = 0;
      const ids = items.map((i) => Number(i.productId)).sort((a, b) => a - b); // fixed lock order avoids deadlocks
      const { rows: prods } = await client.query(
        'SELECT id, price_cents, stock FROM products WHERE id = ANY($1::bigint[]) ORDER BY id FOR UPDATE', [ids]);
      const byId = new Map(prods.map((p) => [Number(p.id), p]));
      const lines = [];
      for (const i of items) {
        const p = byId.get(Number(i.productId));
        if (!p) continue;
        const qty = clampInt(i.qty, 1, 1, 5);
        total += p.price_cents * qty;
        lines.push([p.id, qty, p.price_cents]);
      }
      if (!lines.length) { await client.query('ROLLBACK'); return reply.code(400).send({ error: 'no valid items' }); }
      const { rows: [order] } = await client.query(
        'INSERT INTO orders (user_id, total_cents) VALUES ($1, $2) RETURNING id, created_at', [req.user.sub, total]);
      for (const [pid, qty, price] of lines) {
        await client.query(
          'INSERT INTO order_items (order_id, product_id, qty, price_cents) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING',
          [order.id, pid, qty, price]);
        // restock automatically so a 30-day test never runs out of stock
        await client.query(
          'UPDATE products SET stock = CASE WHEN stock >= $2 THEN stock - $2 ELSE stock + 500 END, updated_at = now() WHERE id = $1',
          [pid, qty]);
      }
      await client.query('COMMIT');
      return reply.code(201).send({ orderId: order.id, totalCents: total });
    } catch (e) {
      await client.query('ROLLBACK').catch(() => {});
      throw e;
    } finally {
      client.release();
    }
  });

  app.get('/orders/me', { preHandler: auth }, async (req) => {
    const { rows } = await pool.query(
      'SELECT id, total_cents, status, created_at FROM orders WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20',
      [req.user.sub]);
    return { items: rows };
  });

  // ---- real-time chat (WebSocket, fan-out across processes/nodes via Redis pub/sub) ----
  const pub = new IORedis(config.redisUrl);
  const sub = new IORedis(config.redisUrl);
  const rooms = new Map(); // room -> Set<socket>
  await sub.psubscribe('chat:*');
  sub.on('pmessage', (_p, channel, msg) => {
    const set = rooms.get(channel.slice(5));
    if (set) for (const s of set) if (s.readyState === 1) s.send(msg);
  });

  app.get('/ws/chat', { websocket: true }, (socket, req) => {
    const room = String(req.query.room ?? 'lobby').slice(0, 40);
    if (!rooms.has(room)) rooms.set(room, new Set());
    rooms.get(room).add(socket);
    wsClients.inc();
    socket.on('message', async (raw) => {
      const body = raw.toString().slice(0, 500);
      const msg = JSON.stringify({ room, body, at: Date.now() });
      pub.publish(`chat:${room}`, msg).catch(() => {});
      pool.query('INSERT INTO chat_messages (room, body) VALUES ($1, $2)', [room, body]).catch(() => {});
    });
    socket.on('close', () => {
      wsClients.dec();
      const set = rooms.get(room);
      set?.delete(socket);
      if (set && !set.size) rooms.delete(room);
    });
  });

  app.get('/chat/:room/history', async (req) => {
    const { rows } = await pool.query(
      'SELECT id, body, created_at FROM chat_messages WHERE room = $1 ORDER BY id DESC LIMIT 50', [req.params.room]);
    return { items: rows };
  });

  // ---- AI features (queued, with back-pressure) ----
  const aiCall = async (reply, kind, data) => {
    try {
      return await runAiJob(kind, data);
    } catch (e) {
      if (e.statusCode === 503) { aiRejected.labels(kind).inc(); return reply.code(503).send({ error: e.message }); }
      throw e;
    }
  };

  app.post('/ai/chat', async (req, reply) => {
    const message = String(req.body?.message ?? '').slice(0, 1000);
    if (!message) return reply.code(400).send({ error: 'message required' });
    return aiCall(reply, 'chat', { type: 'chat', message });
  });

  app.post('/ai/ask', async (req, reply) => {
    const question = String(req.body?.question ?? '').slice(0, 1000);
    if (!question) return reply.code(400).send({ error: 'question required' });
    return aiCall(reply, 'chat', { type: 'ask', question });
  });

  app.post('/ai/voice', async (req, reply) => {
    if (!req.isMultipart()) return reply.code(400).send({ error: 'send audio as multipart/form-data, field "file"' });
    const file = await req.file();
    if (!file) return reply.code(400).send({ error: 'audio file required (multipart field "file")' });
    const ext = path.extname(file.filename || '.wav').slice(0, 6) || '.wav';
    const name = `in-${randomUUID()}${ext}`;
    // audio lives in Redis (shared by every node), so any node's worker can process it: no shared disk needed
    await pub.set(`audio:${name}`, await file.toBuffer(), 'EX', 900);
    // optional language hint: ?lang=bn or a form field "language" sent before the file
    const lang = String(req.query.lang || file.fields?.language?.value || '').toLowerCase();
    return aiCall(reply, 'voice', { file: name, ...(/^[a-z]{2,3}$/.test(lang) && { lang }) });
  });

  // generated speech, stored in Redis by whichever node's worker produced it
  app.get('/files/:name', async (req, reply) => {
    const name = path.basename(req.params.name);
    const buf = await pub.getBuffer(`audio:${name}`);
    if (!buf) return reply.code(404).send({ error: 'expired or not found' });
    return reply.type('audio/wav').header('cache-control', 'private, max-age=3600').send(buf);
  });

  app.setErrorHandler((err, req, reply) => {
    const code = err.statusCode && err.statusCode < 600 ? err.statusCode : 500;
    if (code >= 500) req.log.error(err);
    reply.code(code).send({ error: code >= 500 ? 'internal error' : err.message });
  });

  app.addHook('onClose', async () => { pub.disconnect(); sub.disconnect(); });
  return app;
}
