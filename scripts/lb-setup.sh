#!/usr/bin/env bash
# Starts (or updates) the HAProxy load balancer on the monitoring server.
#   bash scripts/lb-setup.sh n1=10.12.96.6 n2=10.12.96.9      node-name=private-ip, any number of nodes
# Listens on <monitor-private-ip>:8090 (VPC only); stats at :8405/stats, Prometheus metrics at :8405/metrics.
# Runtime control from the monitor:  lbctl n2 drain|maint|ready      lbctl show
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: lb-setup.sh n1=<ip> [n2=<ip> ...]"; exit 1; }
command -v socat >/dev/null || { apt-get update -qq && apt-get install -y -qq socat >/dev/null; }
mkdir -p /etc/uvbench/haproxy /run/haproxy && chmod 777 /run/haproxy
NODES=""; for kv in "$@"; do NODES+="  server ${kv%%=*} ${kv#*=}:80 check"$'\n'; done
awk -v n="$NODES" '{ if ($0 == "__NODES__") printf "%s", n; else print }' monitoring/haproxy/haproxy.cfg.tpl > /etc/uvbench/haproxy/haproxy.cfg
docker run --rm -v /etc/uvbench/haproxy:/usr/local/etc/haproxy:ro haproxy:3.0 haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
docker rm -f uvbench-lb >/dev/null 2>&1 || true
docker run -d --name uvbench-lb --restart unless-stopped --network host --ulimit nofile=200000:200000 \
  -v /etc/uvbench/haproxy:/usr/local/etc/haproxy:ro -v /run/haproxy:/run/haproxy haproxy:3.0 >/dev/null
cat > /usr/local/bin/lbctl <<'X'
#!/usr/bin/env bash
# lbctl show | lbctl <node> drain|maint|ready
if [ "${1:-show}" = show ]; then echo "show servers state nodes" | socat stdio /run/haproxy/admin.sock | awk 'NR>2 && NF>6 {op=($6==2?"UP":($6==0?"DOWN":"starting")); ad=($7==0?"ready":($7%2==1||int($7/32)%2==1?"maint":(int($7/8)%2==1?"drain":"admin"$7))); print $4"="op"/"ad}'
else echo "set server nodes/$1 state $2" | socat stdio /run/haproxy/admin.sock; fi
X
cat > /usr/local/bin/lbwatch <<'X'
#!/usr/bin/env bash
# prints a timestamped line every time a node's LB state changes (for the failover/deploy timeline)
p=""; while sleep 1; do s=$(lbctl show | tr '\n' ' '); [ "$s" != "$p" ] && echo "$(date -u +%H:%M:%SZ) $s"; p=$s; done
X
chmod +x /usr/local/bin/lbctl /usr/local/bin/lbwatch
PIP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -E '^10\.' | head -1)
ufw allow from 10.0.0.0/8 to any port 8090,8405 proto tcp >/dev/null 2>&1 || true
mkdir -p monitoring/prometheus/targets
printf '[{"targets":["%s:8405"],"labels":{"tier":"lb"}}]\n' "$PIP" > monitoring/prometheus/targets/lb-haproxy.json
sleep 6; lbctl show
echo "LB ready: http://$PIP:8090"
