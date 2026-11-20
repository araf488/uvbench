#!/usr/bin/env bash
# API integration test: real PostgreSQL + Redis, mocked AI services. Used by CI and runnable locally.
# Needs env: PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE REDIS_URL (PG must allow CREATE EXTENSION vector).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
export LLM_URL=http://127.0.0.1:58080 EMBED_URL=http://127.0.0.1:58080 STT_URL=http://127.0.0.1:58080 TTS_URL=http://127.0.0.1:58080
export PORT=54000 METRICS_PORT=59400 API_WORKERS=2 FILES_DIR=$(mktemp -d)
B=http://127.0.0.1:$PORT
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT

psql -v ON_ERROR_STOP=1 -q -f "$ROOT/db/init/01-schema.sql"
psql -v ON_ERROR_STOP=1 -q -v n_users=2000 -v n_products=20000 -v n_orders=10000 -f "$ROOT/db/seed.sql"

node test/mock-ai.mjs & pids+=($!)
sleep 1
node src/seed-docs.js 100
node src/server.js & pids+=($!)
node src/worker.js & pids+=($!)
for i in $(seq 30); do curl -fs $B/health >/dev/null && break; sleep 1; done

pass=0; fail=0
expect() { # expect <code> <description> <curl args...>
  local want=$1 desc=$2; shift 2
  local got; got=$(curl -s -o /tmp/it-body -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok   $desc"; else fail=$((fail+1)); echo "  FAIL $desc (got $got, want $want): $(head -c 200 /tmp/it-body)"; fi
}
J=(-H 'content-type: application/json')
expect 200 health            $B/health
expect 200 products          "$B/products?page=2&limit=5"
expect 200 product           $B/products/5
expect 404 product-missing   $B/products/99999999
expect 200 search            "$B/search?q=laptop"
expect 401 login-bad         -X POST "${J[@]}" -d '{"email":"user7@bench.test","password":"nope"}' $B/auth/login
TOKEN=$(curl -fs -X POST "${J[@]}" -d '{"email":"user7@bench.test","password":"bench-pass"}' $B/auth/login | node -pe 'JSON.parse(require("fs").readFileSync(0)).token')
expect 401 order-no-auth     -X POST "${J[@]}" -d '{"items":[{"productId":5,"qty":1}]}' $B/orders
expect 201 order             -X POST "${J[@]}" -H "authorization: Bearer $TOKEN" -d '{"items":[{"productId":5,"qty":2},{"productId":3,"qty":1}]}' $B/orders
expect 200 my-orders         -H "authorization: Bearer $TOKEN" $B/orders/me
expect 200 ai-chat           -X POST "${J[@]}" -d '{"message":"hello"}' $B/ai/chat
expect 200 ai-ask-rag        -X POST "${J[@]}" -d '{"question":"laptop warranty?"}' $B/ai/ask
head -c 4000 /dev/urandom > "$FILES_DIR/../clip.wav"
expect 200 ai-voice          -X POST -F "file=@$FILES_DIR/../clip.wav" $B/ai/voice
expect 400 ai-voice-no-file  -X POST "${J[@]}" -d '{}' $B/ai/voice
node -e "
const a=new WebSocket('ws://127.0.0.1:$PORT/ws/chat?room=ci'),b=new WebSocket('ws://127.0.0.1:$PORT/ws/chat?room=ci');
let n=0;const go=()=>{if(++n==2)a.send('ping')};a.onopen=go;b.onopen=go;
b.onmessage=()=>process.exit(0);setTimeout(()=>process.exit(1),5000);" && { pass=$((pass+1)); echo "  ok   websocket-fanout"; } || { fail=$((fail+1)); echo "  FAIL websocket-fanout"; }
curl -fs http://127.0.0.1:$METRICS_PORT/metrics | grep -q uvbench_http_request_duration_seconds_count \
  && { pass=$((pass+1)); echo "  ok   aggregated-metrics"; } || { fail=$((fail+1)); echo "  FAIL aggregated-metrics"; }
echo "integration: $pass passed, $fail failed"
[ "$fail" = 0 ]
