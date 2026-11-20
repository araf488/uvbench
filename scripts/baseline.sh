#!/usr/bin/env bash
# Phase 0 - read-only baseline of a PRODUCTION server.
# Changes nothing, installs nothing. Safe to run any time.
# Usage:  sudo bash phase0_baseline.sh   -> writes baseline_<hostname>_<date>.txt
set -u
OUT="baseline_$(hostname)_$(date +%Y%m%d_%H%M).txt"
sec() { printf '\n===== %s =====\n' "$1"; }
run() { echo "\$ $*"; eval "$@" 2>&1 || echo "(command failed or not installed)"; }

{
sec "HOST";        run "hostnamectl"; run "uptime"; run "date -u"
sec "CPU";         run "nproc"; run "lscpu | grep -E 'Model name|Socket|Thread|Core|MHz|Hypervisor|L3'"
sec "LOAD + STEAL (5 x 1s samples)"; run "vmstat 1 5"
sec "MEMORY";      run "free -m"; run "swapon --show"
sec "TOP MEMORY PROCESSES"; run "ps -eo pid,user,%cpu,%mem,rss,comm --sort=-rss | head -20"
sec "TOP CPU PROCESSES";    run "ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -15"
sec "DISK";        run "df -hT -x tmpfs -x devtmpfs"; run "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,ROTA"
sec "BIGGEST DIRS under /var"; run "du -xh --max-depth=1 /var 2>/dev/null | sort -h | tail -10"
sec "LISTENING PORTS";  run "ss -tlnp"
sec "DOCKER";      run "docker version --format '{{.Server.Version}}'"; run "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
run "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"
run "docker system df"
sec "SYSTEMD SERVICES (running)"; run "systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print \$1}'"
sec "WEB / DB / MAIL DETECTION"
for s in nginx apache2 caddy postgresql mysql mariadb redis-server postfix dovecot exim4 rspamd clamav-daemon opendkim; do
  systemctl is-active --quiet "$s" 2>/dev/null && echo "active: $s"
done
[ -d /opt/mailcow-dockerized ] && echo "Mailcow detected (/opt/mailcow-dockerized)"
[ -f /etc/iredmail-release ] && echo "iRedMail detected: $(cat /etc/iredmail-release)"
docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'mailcow|postfix|dovecot|rspamd|mailu|poste' | sed 's/^/mail container: /'
sec "MAIL QUEUE";  run "command -v postqueue >/dev/null && postqueue -p | tail -1"
sec "OOM / KERNEL WARNINGS (last 7 days)"; run "journalctl -k --since '7 days ago' --no-pager | grep -iE 'oom|killed process' | tail -20"
sec "FIREWALL";    run "ufw status verbose"
sec "OS UPDATES PENDING"; run "apt list --upgradable 2>/dev/null | wc -l"
} > "$OUT"

echo "Done -> $OUT"
echo "Paste its contents back in the chat (it contains no passwords or keys)."
