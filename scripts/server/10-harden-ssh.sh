#!/usr/bin/env bash
# Phase 2a: SSH. Key-only login, no root login, one allowed user.
#
# Run as root ON THE SERVER, from a session you keep open:
#   sudo ./scripts/server/10-harden-ssh.sh
#
# Lockout protection: after sshd restarts you get 5 minutes to confirm, from a
# SECOND terminal, that you can still log in. No confirmation means the change
# is reverted automatically. Your current session survives the restart either way.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars ADMIN_USER SSH_PORT
detect_os

DROPIN=/etc/ssh/sshd_config.d/00-homelab-playbook.conf
home_dir=$(getent passwd "$ADMIN_USER" | cut -d: -f6) || die "$ADMIN_USER does not exist. Run 00-bootstrap.sh first."
[ -s "$home_dir/.ssh/authorized_keys" ] || die "$ADMIN_USER has no authorized_keys. Turning off passwords now would lock you out."

grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config does not Include sshd_config.d/*.conf; add that line at the TOP first."

backup=""
[ -f "$DROPIN" ] && { backup="$DROPIN.bak.$(date +%s)"; cp "$DROPIN" "$backup"; }
render_template "$PLAYBOOK_ROOT/templates/ssh/00-homelab-playbook.conf" "$DROPIN"
chmod 644 "$DROPIN"

revert() {
  warn "reverting SSH changes"
  if [ -n "$backup" ]; then mv "$backup" "$DROPIN"; else rm -f "$DROPIN"; fi
  systemctl restart "$svc"
  warn "reverted. sshd is back to its previous config."
}

sshd -t || { rm -f "$DROPIN"; [ -n "$backup" ] && mv "$backup" "$DROPIN"; die "sshd rejected the config; nothing was changed"; }

if [ "$SSH_PORT" != "22" ]; then
  if [ "$OS_FAMILY" = rhel ]; then
    need_cmd semanage
    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null \
      || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
    firewall-cmd --permanent --add-port="$SSH_PORT/tcp" && firewall-cmd --reload
  elif ufw status | grep -c 'Status: active' >/dev/null; then
    ufw allow "$SSH_PORT/tcp" comment 'ssh'
  fi
fi

# Ubuntu 22.10+ starts sshd from ssh.socket, which listens on its OWN port
# setting and ignores "Port" in sshd_config. Hand listening back to the service.
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  systemctl disable --now ssh.socket
  systemctl enable ssh.service
fi
svc=sshd; systemctl list-unit-files ssh.service >/dev/null 2>&1 && svc=ssh
systemctl restart "$svc"

log "Effective config (sshd -T), what actually applies:"
eff=$(sshd -T 2>/dev/null)
bad=0
for pair in "port $SSH_PORT" "permitrootlogin no" "passwordauthentication no" "pubkeyauthentication yes" "maxauthtries 3"; do
  if printf '%s\n' "$eff" | grep -cx "$pair" >/dev/null; then ok "$pair"; else fail "expected '$pair'"; bad=1; fi
done
[ "$bad" -eq 0 ] || { revert; die "another config file overrides ours; see 'sshd -T' and /etc/ssh/sshd_config.d/"; }

cat <<EOF

KEEP THIS SESSION OPEN. In a NEW terminal on your laptop run:
    ssh -p $SSH_PORT $ADMIN_USER@<server>
and also prove a password is refused:
    ssh -p $SSH_PORT -o PubkeyAuthentication=no $ADMIN_USER@<server>   (must say Permission denied)
EOF
if [ -t 0 ] && [ "${ASSUME_YES:-0}" != "1" ]; then
  printf 'Did the new login work? Type yes within 5 minutes: '
  if read -r -t 300 answer && [ "$answer" = "yes" ]; then
    [ -n "$backup" ] && rm -f "$backup"
    ok "SSH hardened and confirmed"
  else
    printf '\n'; revert; exit 1
  fi
else
  warn "no terminal to confirm; leaving the change in place (backup: ${backup:-none})"
fi
