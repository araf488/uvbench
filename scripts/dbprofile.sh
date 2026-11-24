#!/usr/bin/env bash
# Which database queries use the CPU? (about 12 minutes, runs ON THE LOAD GENERATOR)
#   bash scripts/dbprofile.sh 2>&1 | tee /root/dbprofile.log
# Puts 600 web users on 2x4c through the LB and samples the running queries on the data node 4 times a second,
# then shows the query plans (EXPLAIN ANALYZE) of every query the web pages use.
set -uo pipefail
P4=144.202.101.118; LB=10.12.96.5:8090
SSH="ssh -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
PSQL="docker exec -i uvbench-db-1 psql -U bench -d bench -At"
ts() { date -u +%H:%M:%SZ; }

echo "[$(ts)] load: 600 web users for 10 min"
bash /opt/uvbench/loadtest/run.sh 4cx2 $LB steady -e AI_WEIGHT=0 -e VUS=600 -e DURATION=10m -e TAGPROFILE=lb-dbprofile \
  | grep -E '^\s*(http_req_failed|http_reqs)[ .:]' &
K=$!
sleep 120
echo "[$(ts)] sampling active queries for about 5 min (share of samples ~ share of database time)"
$SSH root@$P4 "for i in \$(seq 800); do $PSQL -c \"SELECT left(regexp_replace(query, '\\s+', ' ', 'g'), 95) FROM pg_stat_activity WHERE state = 'active' AND backend_type = 'client backend' AND pid <> pg_backend_pid()\"; sleep 0.25; done" \
  | sed -E "s/'[^']*'/'?'/g; s/\\\$[0-9]+/\$n/g" | sort | uniq -c | sort -rn | head -12 \
  | awk '{n=$1; $1=""; t+=n; c[NR]=n; q[NR]=$0} END {for (i=1;i<=NR;i++) printf "%5.1f%%  %s\n", 100*c[i]/t, q[i]}'
wait $K

echo "[$(ts)] query plans"
$SSH root@$P4 "$PSQL" <<'SQL'
\echo === search 'laptop' (10% of page views) ===
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) SELECT id, name, category, price_cents, rating FROM products
  WHERE search @@ plainto_tsquery('english', 'laptop') ORDER BY rating DESC, id LIMIT 20;
\echo === how many products match each search word ===
SELECT w, count(*) FROM unnest(ARRAY['laptop','phone','wireless','camera','speaker','watch','portable','monitor','router','gaming']) w
  JOIN products p ON p.search @@ plainto_tsquery('english', w) GROUP BY w ORDER BY 2 DESC;
\echo === product list, page 150 ===
EXPLAIN (ANALYZE, COSTS OFF) SELECT id, sku, name, category, price_cents, stock, rating FROM products ORDER BY id LIMIT 20 OFFSET 2980;
\echo === product page ===
EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM products WHERE id = 4242;
\echo === my orders ===
EXPLAIN (ANALYZE, COSTS OFF) SELECT id, total_cents, status, created_at FROM orders WHERE user_id = 77 ORDER BY created_at DESC LIMIT 20;
\echo === chat history ===
EXPLAIN (ANALYZE, COSTS OFF) SELECT id, body, created_at FROM chat_messages WHERE room = 'room7' ORDER BY id DESC LIMIT 50;
\echo === table sizes ===
SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;
SQL
echo "[$(ts)] done"
