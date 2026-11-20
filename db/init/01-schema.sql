-- UVBench reference app schema (PostgreSQL 16 + pgvector)
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS users (
  id          BIGSERIAL PRIMARY KEY,
  email       TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  pw_hash     TEXT NOT NULL,              -- benchmark users share one known test hash
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
  id          BIGSERIAL PRIMARY KEY,
  sku         TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  category    TEXT NOT NULL,
  description TEXT NOT NULL,
  price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
  stock       INTEGER NOT NULL DEFAULT 0,
  rating      NUMERIC(2,1) NOT NULL DEFAULT 0,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  search      TSVECTOR GENERATED ALWAYS AS (
                to_tsvector('english', name || ' ' || category || ' ' || description)) STORED
);
CREATE INDEX IF NOT EXISTS products_category_idx ON products (category, id);
CREATE INDEX IF NOT EXISTS products_search_idx   ON products USING GIN (search);

CREATE TABLE IF NOT EXISTS orders (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT NOT NULL REFERENCES users(id),
  total_cents INTEGER NOT NULL,
  status      TEXT NOT NULL DEFAULT 'placed',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_user_idx ON orders (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS order_items (
  order_id    BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id  BIGINT NOT NULL REFERENCES products(id),
  qty         INTEGER NOT NULL CHECK (qty > 0),
  price_cents INTEGER NOT NULL,
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id          BIGSERIAL PRIMARY KEY,
  room        TEXT NOT NULL,
  user_id     BIGINT,
  body        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chat_room_idx ON chat_messages (room, id DESC);

-- Knowledge base for the AI assistant (RAG). 768 dims = nomic-embed-text-v1.5
CREATE TABLE IF NOT EXISTS documents (
  id          BIGSERIAL PRIMARY KEY,
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  embedding   vector(768)
);

CREATE TABLE IF NOT EXISTS ai_requests (
  id          BIGSERIAL PRIMARY KEY,
  kind        TEXT NOT NULL,              -- chat | ask | voice
  user_id     BIGINT,
  ms_total    INTEGER,
  ms_stt      INTEGER,
  ms_llm      INTEGER,
  ms_tts      INTEGER,
  tokens_out  INTEGER,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
