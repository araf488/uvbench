import { notFound } from 'next/navigation';
import { api, money } from '../../../lib/api';

export const dynamic = 'force-dynamic';

export default async function Product({ params }) {
  const { id } = await params;
  if (!/^\d+$/.test(id)) notFound();
  const p = await api(`/products/${id}`, { cache: 'no-store' });
  if (!p) notFound();
  return (
    <div className="card">
      <h1>{p.name}</h1>
      <p className="muted">{p.sku} · {p.category} · ★ {p.rating} · {p.stock} in stock</p>
      <p>{p.description}</p>
      <h2>{money(p.price_cents)}</h2>
      <a href="/assistant">Ask the AI assistant about this product →</a>
    </div>
  );
}
