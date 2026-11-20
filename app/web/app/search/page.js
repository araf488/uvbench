import { api, money } from '../../lib/api';

export const dynamic = 'force-dynamic';

export default async function Search({ searchParams }) {
  const sp = await searchParams;
  const q = String(sp?.q ?? '').slice(0, 100);
  const data = q ? await api(`/search?q=${encodeURIComponent(q)}`, { cache: 'no-store' }) : { items: [] };
  return (
    <>
      <form><input name="q" defaultValue={q} placeholder="Search products" /></form>
      <h1>Results for “{q}”</h1>
      <div className="grid">
        {data.items.map((p) => (
          <div className="card" key={p.id}>
            <a href={`/products/${p.id}`}><strong>{p.name}</strong></a>
            <div className="muted">{p.category}</div>
            <div>{money(p.price_cents)}</div>
          </div>
        ))}
      </div>
    </>
  );
}
