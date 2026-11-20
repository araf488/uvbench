// Seeds the AI knowledge base (RAG): N synthetic support articles + their embeddings.
// Usage (inside the api container): node src/seed-docs.js 2000
import { pool } from './db.js';
import { embedDocuments, toPgVector } from './ai.js';

const N = parseInt(process.argv[2] ?? '2000', 10);
const topics = ['warranty', 'shipping', 'returns', 'battery care', 'setup', 'firmware updates', 'payments',
  'order tracking', 'repairs', 'accessories', 'data privacy', 'store pickup'];
const products = ['Phone', 'Laptop', 'Headset', 'Watch', 'Camera', 'Speaker', 'Monitor', 'Tablet', 'Router', 'Keyboard'];

function article(i) {
  const t = topics[i % topics.length];
  const p = products[(i * 7) % products.length];
  const days = 7 + (i % 5) * 7;
  return {
    title: `${p} ${t} guide #${i}`,
    body: `For every ${p.toLowerCase()} we sell, our ${t} policy works like this: customers can contact support within ` +
      `${days} days, keep the receipt and order number ready, and use the app to open a request. ` +
      `Premium members get priority handling within ${1 + (i % 3)} business days. ` +
      `Tip ${i}: restart the ${p.toLowerCase()} and update firmware before contacting support.`,
  };
}

const { rows: [{ count }] } = await pool.query('SELECT count(*)::int AS count FROM documents');
if (count >= N) { console.log(`documents already seeded (${count})`); process.exit(0); }

const batch = 32;
for (let i = count; i < N; i += batch) {
  const docs = Array.from({ length: Math.min(batch, N - i) }, (_, k) => article(i + k));
  const vecs = await embedDocuments(docs.map((d) => `${d.title}. ${d.body}`));
  const values = []; const params = [];
  docs.forEach((d, k) => {
    params.push(d.title, d.body, toPgVector(vecs[k]));
    values.push(`($${k * 3 + 1}, $${k * 3 + 2}, $${k * 3 + 3}::vector)`);
  });
  await pool.query(`INSERT INTO documents (title, body, embedding) VALUES ${values.join(',')}`, params);
  process.stdout.write(`\rembedded ${i + docs.length}/${N}`);
}
await pool.query('CREATE INDEX IF NOT EXISTS documents_embedding_idx ON documents USING hnsw (embedding vector_cosine_ops)');
console.log('\nRAG documents ready');
await pool.end();
