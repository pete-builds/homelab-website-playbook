#!/usr/bin/env bash
# Phase 2c: fail2ban. Bans IPs that keep failing SSH logins, and bans repeat
# offenders for a week.
#
# Run as root ON THE SERVER:  sudo ./scripts/server/30-fail2ban.sh
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars SSH_PORT
detect_os
need_cmd fail2ban-client

LAN_CIDR_OR_LOOPBACK="${LAN_CIDR:-127.0.0.1/8}"
if [ "$OS_FAMILY" = debian ]; then BANACTION=ufw; else BANACTION=firewallcmd-rich-rules; fi
export LAN_CIDR_OR_LOOPBACK BANACTION

render_template "$PLAYBOOK_ROOT/templates/fail2ban/jail.local" /etc/fail2ban/jail.local
touch /var/log/fail2ban.log
fail2ban-client -t >/dev/null || die "fail2ban rejected jail.local"
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2

for jail in sshd recidive; do
  if fail2ban-client status "$jail" >/dev/null 2>&1; then ok "jail $jail is running"; else fail "jail $jail is NOT running"; exit 1; fi
done
