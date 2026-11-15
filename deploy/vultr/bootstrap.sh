#!/usr/bin/env bash
# One-time setup of a fresh Vultr instance (Ubuntu 22.04/24.04 or Debian 12), run as root:
#
#   ssh root@<instance-ip> 'bash -s' -- "$(cat ~/.ssh/drainsense_deploy.pub)" < deploy/vultr/bootstrap.sh
#
# Installs Docker Engine and the Compose plugin, creates the `deploy` user that GitHub Actions logs
# in as (with the given public key), creates /opt/drainsense, opens 80/443 in ufw (Vultr's Ubuntu
# images ship with ufw on and only SSH open), and adds a 2 GB swap file on instances under 2 GB RAM.
# Safe to run again.
#
# Note: membership of the docker group is root-equivalent on this host. Keep the private key in
# GitHub secrets only.
set -euo pipefail

pubkey="${1:?usage: bootstrap.sh '<ssh public key for the deploy user>'}"
deploy_user="${DEPLOY_USER:-deploy}"

log() { printf '== %s\n' "$*"; }

[[ "$(id -u)" == "0" ]] || { echo "Run as root." >&2; exit 1; }

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  log "install Docker"
  apt-get update -q
  apt-get install -yq ca-certificates curl
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

if ! id "$deploy_user" >/dev/null 2>&1; then
  log "create user ${deploy_user}"
  useradd --create-home --shell /bin/bash "$deploy_user"
fi
usermod -aG docker "$deploy_user"
home="$(getent passwd "$deploy_user" | cut -d: -f6)"
install -d -m 700 -o "$deploy_user" -g "$deploy_user" "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -qxF "$pubkey" "$home/.ssh/authorized_keys" || printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys"
chown "$deploy_user:$deploy_user" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

install -d -m 755 -o "$deploy_user" -g "$deploy_user" /opt/drainsense

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  log "open 80/tcp, 443/tcp, 443/udp in ufw"
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
fi

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
if (( mem_kb < 2000000 )) && [[ -z "$(swapon --show --noheadings)" ]]; then
  log "add 2 GB swap"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "done: $(docker --version), $(docker compose version)"
log "GitHub secrets: VULTR_HOST=$(curl -fsS -4 -m 5 https://ifconfig.me 2>/dev/null || hostname -I | cut -d' ' -f1)  VULTR_USER=${deploy_user}"
