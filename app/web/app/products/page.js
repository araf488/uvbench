import { api, money } from '../../lib/api';

export const dynamic = 'force-dynamic'; // full SSR on every request (uncached path)

export default async function Products({ searchParams }) {
  const sp = await searchParams;
  const page = Math.max(1, parseInt(sp?.page ?? '1', 10) || 1);
  const category = sp?.category ? `&category=${encodeURIComponent(sp.category)}` : '';
  const data = await api(`/products?page=${page}&limit=24${category}`, { cache: 'no-store' });
  return (
    <>
      <h1>Products · page {page}</h1>
      <div className="grid">
        {data.items.map((p) => (
          <div className="card" key={p.id}>
            <a href={`/products/${p.id}`}><strong>{p.name}</strong></a>
            <div className="muted">{p.category} · stock {p.stock}</div>
            <div>{money(p.price_cents)}</div>
          </div>
        ))}
      </div>
      <p className="pager">
        {page > 1 && <a href={`/products?page=${page - 1}`}>← Previous</a>}
        <a href={`/products?page=${page + 1}`}>Next →</a>
      </p>
    </>
  );
}
