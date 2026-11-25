#!/usr/bin/env bash
# For a test server OUTSIDE the private network (e.g. a GPU in another region): every port, including the ones
# Docker publishes (Docker bypasses ufw), is reachable only from the listed IPs. SSH stays open (key-only).
#   bash scripts/public-firewall.sh 149.28.199.74 45.77.187.211        (load generator, monitor)
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: public-firewall.sh <allowed-ip>..."; exit 1; }
IF=$(ip -4 route show default | awk '{print $5; exit}')
cat > /usr/local/sbin/uvbench-fw <<X
#!/usr/bin/env bash
iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER
iptables -A DOCKER-USER -i $IF -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
$(for ip in "$@"; do echo "iptables -A DOCKER-USER -i $IF -s $ip -j RETURN"; done)
iptables -A DOCKER-USER -i $IF -j DROP
iptables -A DOCKER-USER -j RETURN
X
chmod +x /usr/local/sbin/uvbench-fw
cat > /etc/systemd/system/uvbench-fw.service <<'X'
[Unit]
Description=uvbench: only allowed IPs may reach Docker-published ports
After=docker.service
Requires=docker.service
PartOf=docker.service        # re-applied whenever Docker restarts
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/uvbench-fw
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target docker.service
X
systemctl daemon-reload && systemctl enable --now uvbench-fw.service >/dev/null
for ip in "$@"; do ufw allow from "$ip" >/dev/null; done
iptables -S DOCKER-USER
