// Server-side calls go straight to the API container; the browser uses /api via Nginx.
const API = process.env.API_INTERNAL_URL || 'http://api:4000';

export async function api(path, init = {}) {
  const res = await fetch(`${API}${path}`, init);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`API ${path} -> ${res.status}`);
  return res.json();
}

export const money = (cents) => `$${(cents / 100).toFixed(2)}`;
