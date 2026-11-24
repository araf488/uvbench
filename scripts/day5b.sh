#!/usr/bin/env bash
# Day 5b: re-test after two fixes found on Day 5 (about 3 hours, runs ON THE LOAD GENERATOR, unattended):
#   - Next.js could not write its page cache (permission bug in the web image) -> every tier re-rendered pages
#   - HAProxy: no per-node connection cap, 30 s queue, logs failed requests
# Start (from your Mac, after syncing the kit):
#   ssh root@149.28.199.74 'systemd-run --unit uvbench-day5b --collect bash -c "cd /opt/uvbench && bash scripts/day5b.sh > /root/day5b.log 2>&1"'
set -uo pipefail
P8=149.28.194.86; I8=10.12.96.3; LG=149.28.199.74; MON=45.77.187.211
P4=144.202.101.118; I4=10.12.96.6; P4B=45.77.4.117; I4B=10.12.96.8; LB=10.12.96.5:8090
SSH="ssh -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
DC='docker compose --env-file .env -f compose/docker-compose.yml'
ts() { date -u +%H:%M:%SZ; }
ev() { echo "[$(ts)] EVENT $*"; }
on() { local h=$1; shift; $SSH root@$h "cd /opt/uvbench && $*"; }
k6sum() { grep -E '^\s*(http_req_failed|http_reqs|vus_max)[ .:]' | head -3; }
run() { bash /opt/uvbench/loadtest/run.sh "$@" | k6sum; }
crash() { on $1 "kill -9 \$(docker inspect -f '{{.State.Pid}}' uvbench-nginx-1)"; }   # a real crash: Docker restarts it

echo "[$(ts)] 1/7 pausing the 8c 24/7 load"
systemctl stop uvbench-spike.timer uvbench-continuous; sleep 3

echo "[$(ts)] 2/7 rebuilding the web image (cache fix) on 4c, 4cb and 8c; 8c also gets 4 parallel transcriptions"
for h in $P4 $P4B $P8; do
  on $h "$DC build -q web && $DC up -d --no-deps web >/dev/null 2>&1 && $DC restart nginx >/dev/null 2>&1; sleep 10; curl -fs -o /dev/null -w '  $h web %{http_code}\n' http://127.0.0.1/"
done
on $P8 "bash scripts/switch-profile.sh standard | grep profile="
sleep 40
for h in $P4 $P4B $P8; do
  on $h "curl -fs -o /dev/null http://127.0.0.1/; sleep 2; echo \"  $h cache errors since fix: \$($DC logs --since 2m web 2>&1 | grep -c EACCES)\""
done

echo "[$(ts)] 3/7 load balancer with the new settings"
on $MON "bash scripts/lb-setup.sh n1=$I4 n2=$I4B | tail -3"
on $MON "lbctl show" | grep -q 'n1=UP/ready' && on $MON "lbctl show" | grep -q 'n2=UP/ready' \
  || { echo "[$(ts)] ERROR: both nodes must be UP - stopping"; exit 1; }
on $MON "pkill -f '[/]usr/local/bin/lbwatch'; nohup lbwatch > /root/lbstate-b.log 2>&1 < /dev/null &"

echo "[$(ts)] 4/7 web-only ladder 2x4c through the LB (before fix: smooth 640 / limit 780)"
ev "lb-web-ladder2 start"; run 4cx2 $LB ladder -e AI_WEIGHT=0 -e START_VUS=500 -e MAX_VUS=2500 -e TAGPROFILE=lb-web-ladder2; ev "lb-web-ladder2 end"

echo "[$(ts)] 5/7 crash test under steady load (600 web users, 16 min): nginx process killed, Docker restarts it"
run 4cx2 $LB steady -e AI_WEIGHT=0 -e VUS=600 -e DURATION=16m -e TAGPROFILE=lb-crash2 &
K=$!
sleep 240; ev "crash nginx on 4c"; crash $P4; sleep 20; on $P4 "docker ps --filter name=uvbench-nginx-1 --format '  {{.Names}} {{.Status}}'"
sleep 340; ev "crash nginx on 4cb"; crash $P4B; sleep 20; on $P4B "docker ps --filter name=uvbench-nginx-1 --format '  {{.Names}} {{.Status}}'"
wait $K; ev "crash test end"
echo "LB state changes:"; on $MON "pkill -f '[/]usr/local/bin/lbwatch'; cat /root/lbstate-b.log"
echo "LB failed-request log (last 15):"; on $MON "docker logs --since 75m uvbench-lb 2>&1 | grep -v ' 200 ' | tail -15"

echo "[$(ts)] 6/7 web-only ladder 1x4c, direct (before fix: smooth 490 / limit 600)"
ev "4c web-ladder2 start"; run 4c $I4 ladder -e AI_WEIGHT=0 -e START_VUS=400 -e MAX_VUS=2000 -e TAGPROFILE=web-ladder2; ev "4c web-ladder2 end"

echo "[$(ts)] 7/7 web-only ladder 1x8c (before fix: smooth 1,050 / limit 1,300)"
ev "8c web-ladder2 start"; run 8c $I8 ladder -e AI_WEIGHT=0 -e START_VUS=900 -e MAX_VUS=3000 -e TAGPROFILE=web-ladder2; ev "8c web-ladder2 end"

systemctl start uvbench-continuous uvbench-spike.timer; sleep 5
echo "[$(ts)] 8c 24/7 load restarted ($(pgrep -fc 'TIER=8c') k6 processes)"
echo "[$(ts)] Day 5b done."
