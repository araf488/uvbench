#!/usr/bin/env bash
# Shared helpers for the bootstrap scripts. Source it; don't run it.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/8}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" = 0 ] || die "run as root (sudo -i)"; }

private_ip() {
  # Vultr VPC addresses are 10.x; first one found wins. Override with PRIVATE_IP=...
  if [ -n "${PRIVATE_IP:-}" ]; then echo "$PRIVATE_IP"; return; fi
  ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -E '^10\.' | head -1
}

base_setup() {
  log "Updating packages and hardening"
  apt-get update -y -q && apt-get upgrade -y -q
  apt-get install -y -q ufw fail2ban htop sysbench fio iperf3 curl jq unzip ca-certificates sysstat
  if ls /root/.ssh/authorized_keys >/dev/null 2>&1 && [ -s /root/.ssh/authorized_keys ]; then
    sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw allow from "$VPC_CIDR" >/dev/null          # private network: monitoring + load traffic
  ufw --force enable >/dev/null
  cat > /etc/sysctl.d/90-uvbench.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2000000
vm.swappiness = 10
EOF
  sysctl --system >/dev/null
  grep -q 'uvbench nofile' /etc/security/limits.conf || cat >> /etc/security/limits.conf <<'EOF'
# uvbench nofile
* soft nofile 1000000
* hard nofile 1000000
EOF
  timedatectl set-timezone UTC
}

add_swap() { # add_swap <GB>
  [ "$1" -gt 0 ] || return 0
  swapon --show | grep -q /swapfile && return 0
  log "Adding ${1} GB swap"
  fallocate -l "${1}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

install_docker() {
  command -v docker >/dev/null && return 0
  log "Installing Docker"
  curl -fsSL https://get.docker.com | sh
  cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" }, "live-restore": true }
EOF
  systemctl restart docker
}
