#!/usr/bin/env bash
# Re-test web capacity on the 8-core (the 4-core pair was deleted) with the search cache on (Day 5 finding: search was ~all the database CPU).
# Runs ON THE LOAD GENERATOR, about 2 hours, unattended:
#   systemd-run --unit uvbench-dbfix --collect bash -c "cd /opt/uvbench && bash scripts/dbfix.sh > /root/dbfix.log 2>&1"
set -uo pipefail
P8=149.28.194.86; I8=10.12.96.3; P4=144.202.101.118; I4=10.12.96.6; P4B=45.77.4.117; LB=10.12.96.5:8090
SSH="ssh -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
DC='docker compose --env-file .env -f compose/docker-compose.yml'
ts() { date -u +%H:%M:%SZ; }
on() { local h=$1; shift; $SSH root@$h "cd /opt/uvbench && $*"; }
k6sum() { grep -E '^\s*(http_req_failed|http_reqs|vus_max)[ .:]' | head -3; }
run() { bash /opt/uvbench/loadtest/run.sh "$@" | k6sum; }
enable() {   # enable <host>: search cache 60 s, rebuild + restart the API (nginx re-resolves it)
  on $1 "sed -i '/^SEARCH_CACHE_SEC=/d' .env; echo SEARCH_CACHE_SEC=60 >> .env
         $DC build -q api && $DC up -d --no-deps api worker >/dev/null 2>&1 && $DC restart nginx >/dev/null 2>&1; sleep 10
         curl -s -o /dev/null -w '  $1 search %{http_code} ' 'http://127.0.0.1/api/search?q=laptop'
         curl -s -D - -o /dev/null 'http://127.0.0.1/api/search?q=laptop' | grep -i x-cache || echo '(no cache header!)'"
}

echo "[$(ts)] 1/2 search cache on: 8c (8c 24/7 load paused)"
systemctl stop uvbench-spike.timer uvbench-continuous; sleep 3
enable $P8

echo "[$(ts)] 2/2 web-only ladder 1x8c (cache off: smooth ~1,090 / limit ~1,320)"
run 8c $I8 ladder -e AI_WEIGHT=0 -e START_VUS=1000 -e MAX_VUS=3500 -e TAGPROFILE=web-ladder3

systemctl start uvbench-continuous uvbench-spike.timer
echo "[$(ts)] dbfix done (8c 24/7 load restarted, search cache stays on)"
