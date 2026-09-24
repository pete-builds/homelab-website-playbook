#!/usr/bin/env bash
# Phase 2b: firewall. Deny every inbound connection except SSH.
#
# Your website needs NO open inbound port. The Cloudflare tunnel dials OUT to
# Cloudflare, and visitors arrive through that connection. So the only door is
# SSH, and if LAN_CIDR is set, only from your home network.
#
# Run as root ON THE SERVER:  sudo ./scripts/server/20-firewall.sh
#
# Docker warning: ports that Docker publishes on 0.0.0.0 BYPASS ufw entirely,
# because Docker writes its own iptables rules ahead of ufw's. That's why every
# compose file here binds to 127.0.0.1. scripts/server/audit.sh flags any
# container port published on all interfaces.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars SSH_PORT ADMIN_USER
detect_os

if [ "$OS_FAMILY" = debian ]; then
  need_cmd ufw
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  if [ -n "${LAN_CIDR:-}" ]; then
    ufw allow from "$LAN_CIDR" to any port "$SSH_PORT" proto tcp comment 'ssh from LAN'
    ok "SSH allowed from $LAN_CIDR only"
  else
    ufw limit "$SSH_PORT/tcp" comment 'ssh (rate limited)'
    ok "SSH allowed from anywhere, rate limited"
  fi
  ufw --force enable
  ufw status verbose
else
  need_cmd firewall-cmd
  zone=$(firewall-cmd --get-default-zone)
  for s in $(firewall-cmd --permanent --zone="$zone" --list-services); do
    firewall-cmd --permanent --zone="$zone" --remove-service="$s" >/dev/null
  done
  for p in $(firewall-cmd --permanent --zone="$zone" --list-ports); do
    firewall-cmd --permanent --zone="$zone" --remove-port="$p" >/dev/null
  done
  if [ -n "${LAN_CIDR:-}" ]; then
    firewall-cmd --permanent --zone="$zone" \
      --add-rich-rule="rule family=ipv4 source address=$LAN_CIDR port port=$SSH_PORT protocol=tcp accept"
    ok "SSH allowed from $LAN_CIDR only"
  else
    firewall-cmd --permanent --zone="$zone" --add-port="$SSH_PORT/tcp"
    ok "SSH allowed from anywhere"
  fi
  firewall-cmd --reload
  firewall-cmd --zone="$zone" --list-all
fi

cat <<EOF

Prove it from your LAPTOP, not from the server (a check run on the server
itself goes through loopback and proves nothing):
    ssh -p $SSH_PORT $ADMIN_USER@<server> true && echo ssh-ok
    nc -zv -w 3 <server> 80    # must FAIL: nothing listens to the outside
EOF
