-- Synthetic seed data. Run by scripts/seed.sh, which passes:
--   psql -v n_users=100000 -v n_products=1000000 -v n_orders=500000 -f seed.sql

-- every benchmark user logs in with password "bench-pass" (bcrypt-free on purpose: sha256, test data only)
INSERT INTO users (email, name, pw_hash)
SELECT 'user' || g || '@bench.test', 'User ' || g, encode(sha256('bench-pass'::bytea), 'hex')
FROM generate_series(1, :n_users) g
ON CONFLICT DO NOTHING;

INSERT INTO products (sku, name, category, description, price_cents, stock, rating)
SELECT 'SKU-' || g,
       (ARRAY['Smart','Classic','Eco','Pro','Ultra','Mini','Max','Lite'])[1 + g % 8] || ' ' ||
       (ARRAY['Phone','Laptop','Headset','Watch','Camera','Speaker','Monitor','Tablet','Router','Keyboard'])[1 + g % 10] || ' ' || g,
       (ARRAY['electronics','audio','computers','wearables','home','office','gaming','network'])[1 + g % 8],
       'Reliable ' || (ARRAY['wireless','compact','durable','fast','quiet','portable'])[1 + g % 6] ||
       ' device with ' || (ARRAY['long battery life','warranty support','fast charging','HD display','low latency','smart features'])[1 + g % 6] ||
       '. Model year ' || (2018 + g % 9) || '.',
       500 + (g * 7919) % 200000,
       (g * 31) % 500,
       round(((g % 50) / 10.0)::numeric, 1)
FROM generate_series(1, :n_products) g
ON CONFLICT DO NOTHING;

INSERT INTO orders (user_id, total_cents, status, created_at)
SELECT 1 + (g * 7) % :n_users, 1000 + (g * 13) % 90000,
       (ARRAY['placed','paid','shipped','delivered'])[1 + g % 4],
       now() - ((g % 365) || ' days')::interval
FROM generate_series(1, :n_orders) g;

INSERT INTO order_items (order_id, product_id, qty, price_cents)
SELECT o.id, 1 + (o.id * 17) % :n_products, 1 + o.id % 3, 500 + (o.id * 11) % 50000
FROM orders o
ON CONFLICT DO NOTHING;

ANALYZE;
