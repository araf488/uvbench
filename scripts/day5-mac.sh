#!/usr/bin/env bash
# Day 5: scale-out (2 x 4-core behind a load balancer) vs 1 x 8-core, zero-downtime deploy and failover.
# Driven from your Mac, about 3.5 hours, unattended:
#   caffeinate -i bash ~/Downloads/uvbench/scripts/day5-mac.sh 2>&1 | tee ~/Downloads/day5.log
#
#  1. pauses the 8c 24/7 load (so the load generator is not shared)   2. updates 4c (data node) to the current kit
#  3. sets up 4cb as an app-only node using 4c's database + Redis     4. HAProxy load balancer on the monitor (VPC only)
#  5. web-only ladder through the LB   6. mixed (with AI) ladder through the LB
#  7. deploy test: naive restart vs rolling deploy with drain   8. failover: reboot one node, crash a process on the other
#  9. restarts the 8c 24/7 load
set -uo pipefail
P8=149.28.194.86; LG=149.28.199.74; MON=45.77.187.211
P4=144.202.101.118; I4=10.12.96.6        # bench-4c: tier + data node (PostgreSQL, Redis)
P4B=45.77.4.117                          # bench-4cb: app-only node
KIT=$(cd "$(dirname "$0")/.." && pwd)
SSH="ssh -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
ts() { date -u +%H:%M:%SZ; }
ev() { echo "[$(ts)] EVENT $*"; }
on() { local h=$1; shift; $SSH root@$h "cd /opt/uvbench && $*"; }
k6sum() { grep -E '^\s*(http_req_failed|http_reqs|vus_max)[ .:]' | head -3; }
lb() { on $MON "lbctl $*"; }
DC='docker compose --env-file .env -f compose/docker-compose.yml'

echo "[$(ts)] 1/9 pausing the 8c 24/7 load; stopping any old 4c test"
on $LG "systemctl stop uvbench-spike.timer uvbench-continuous; pkill -f '[o]vernight.sh.* 4c' ; pkill -f '[T]IER=4c -e'; sleep 3; pgrep -fc 'k6 run' || true"

echo "[$(ts)] 2/9 updating the kit everywhere; 4c app containers restart (database and Redis untouched)"
on $MON "test -f monitoring/docker-compose.yml" || { echo "monitor kit not in /opt/uvbench - stop and tell Claude"; exit 1; }
until $SSH -o ConnectTimeout=5 root@$P4B true 2>/dev/null; do echo "  waiting for bench-4cb to boot..."; sleep 15; done
for h in $P4 $P4B; do rsync -az -e "$SSH" --exclude node_modules --exclude .next --exclude models --exclude .env "$KIT/" root@$h:/opt/uvbench/; done
rsync -az -e "$SSH" "$KIT/loadtest/" root@$LG:/opt/uvbench/loadtest/
rsync -az -e "$SSH" --exclude node_modules --exclude .next --exclude models --exclude .env \
  --exclude monitoring/.env --exclude 'monitoring/prometheus/targets/' --exclude 'monitoring/grafana/dashboards/' "$KIT/" root@$MON:/opt/uvbench/
on $P4 "$DC build -q api stt && $DC up -d --no-deps api worker stt && sleep 15 && curl -fs http://127.0.0.1/api/health && echo"

echo "[$(ts)] 3/9 setting up bench-4cb as an app node (about 10-15 min)"
$SSH root@$P4 cat /root/.uvbench-secrets | $SSH root@$P4B "cat > /root/.uvbench-secrets && chmod 600 /root/.uvbench-secrets"
on $P4B "bash scripts/bootstrap-appnode.sh 4c $I4 2>&1 | grep -vE 'Pulling|Downloading|Extracting|Waiting|Verifying|#[0-9]+ ' | tail -20"
I4B=$(on $P4B "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -E '^10\.' | head -1")
echo "  bench-4cb private IP: $I4B"
on $MON "bash scripts/monitor-add-target.sh 4cb $I4B app"

echo "[$(ts)] 4/9 load balancer (HAProxy on the monitor)"
on $MON "bash scripts/lb-setup.sh n1=$I4 n2=$I4B && curl -fs -X POST http://127.0.0.1:9090/-/reload && echo prometheus reloaded"
LBIP=$(on $MON "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | grep -E '^10\.' | head -1")
LB="$LBIP:8090"; echo "  LB = http://$LB"
on $LG "for i in 1 2 3 4; do curl -fs http://$LB/api/health; echo; done"
# log every LB state change (node up/down/drain) with a timestamp, for the report
on $MON "pkill -f '[/]usr/local/bin/lbwatch'; nohup lbwatch > /root/lbstate.log 2>&1 < /dev/null &"
run() { on $LG "bash loadtest/run.sh 4cx2 $LB $*" | k6sum; }

echo "[$(ts)] 5/9 web-only ladder through the LB (compare: 1x8c ~1,300 users, 1x4c ~600)"
ev "lb-web-ladder start"; run ladder -e AI_WEIGHT=0 -e START_VUS=400 -e MAX_VUS=2000 -e TAGPROFILE=lb-web-ladder; ev "lb-web-ladder end"

echo "[$(ts)] 6/9 mixed (with AI) ladder through the LB (compare: 1x8c ~50 users, 1x4c ~50)"
ev "lb-mixed-ladder start"; run ladder -e START_VUS=40 -e TAGPROFILE=lb-mixed-ladder; ev "lb-mixed-ladder end"

echo "[$(ts)] 7/9 deploy test under steady load (600 web users, 22 min)"
on $LG "bash loadtest/run.sh 4cx2 $LB steady -e AI_WEIGHT=0 -e VUS=600 -e DURATION=22m -e TAGPROFILE=lb-deploy" | k6sum &
K=$!
sleep 240
ev "naive restart of 4cb (no drain)"; on $P4B "$DC up -d --no-deps --force-recreate web api worker nginx >/dev/null 2>&1"; ev "naive restart done"
sleep 360
for n in "n2 $P4B" "n1 $P4"; do set -- $n
  ev "rolling deploy $1: drain"; lb $1 drain; sleep 20; lb $1 maint
  on $2 "$DC up -d --no-deps --force-recreate web api worker nginx >/dev/null 2>&1; for i in \$(seq 90); do curl -fs http://127.0.0.1/api/health >/dev/null && break; sleep 2; done"
  sleep 10; lb $1 ready; ev "rolling deploy $1: back in service"; sleep 60
done
wait $K; ev "deploy test end"

echo "[$(ts)] 8/9 failover test under steady load (600 web users, 22 min)"
on $LG "bash loadtest/run.sh 4cx2 $LB steady -e AI_WEIGHT=0 -e VUS=600 -e DURATION=22m -e TAGPROFILE=lb-failover" | k6sum &
K=$!
sleep 240
ev "power-cut style: rebooting bench-4cb"; on $P4B "systemctl reboot" >/dev/null 2>&1 || true
sleep 30; until $SSH -o ConnectTimeout=5 root@$P4B "curl -fs http://127.0.0.1/api/health" >/dev/null 2>&1; do sleep 5; done
ev "bench-4cb back and healthy"
sleep 300
ev "crash: killing nginx on bench-4c (Docker restarts it)"; on $P4 "docker kill uvbench-nginx-1 >/dev/null"
sleep 60; on $P4 "docker ps --filter name=uvbench-nginx-1 --format '{{.Names}} {{.Status}}'"
wait $K; ev "failover test end"
echo "LB state changes:"; on $MON "pkill -f '[/]usr/local/bin/lbwatch'; cat /root/lbstate.log"

echo "[$(ts)] 9/9 restarting the 8c 24/7 load"
on $LG "systemctl start uvbench-continuous uvbench-spike.timer; sleep 5; pgrep -fc 'TIER=8c'"
echo "[$(ts)] Day 5 done. Paste ~/Downloads/day5.log to Claude. (4c + 4cb + LB stay up until Day 6.)"
