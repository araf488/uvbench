import { api, money } from '../lib/api';

// ISR: rendered on the server, cached and regenerated at most every 30 s
export const revalidate = 30;

export default async function Home() {
  let items = [];
  try {
    items = (await api('/products?page=1&limit=12', { next: { revalidate: 30 } }))?.items ?? [];
  } catch {
    // API not reachable at build time; the page is regenerated at runtime
  }
  return (
    <>
      <h1>Featured products</h1>
      <p className="muted">Server-rendered with incremental static regeneration (30 s).</p>
      <div className="grid">
        {items.map((p) => (
          <div className="card" key={p.id}>
            <a href={`/products/${p.id}`}><strong>{p.name}</strong></a>
            <div className="muted">{p.category} · ★ {p.rating}</div>
            <div>{money(p.price_cents)}</div>
          </div>
        ))}
      </div>
    </>
  );
}
