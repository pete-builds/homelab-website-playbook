#!/usr/bin/env bash
# Phase 1: first boot. Creates your admin user, installs your SSH key, sets the
# timezone and installs the base packages every later phase needs.
#
# Run as root ON THE SERVER:   sudo ./scripts/server/00-bootstrap.sh
# Safe to re-run: every step checks before it changes anything.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars ADMIN_USER TIMEZONE
detect_os

log "Base packages ($OS_FAMILY)"
if [ "$OS_FAMILY" = debian ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q curl ca-certificates git sudo openssh-server ufw fail2ban \
    unattended-upgrades apt-listchanges needrestart python3 rsync
else
  # fail2ban lives in EPEL on Alma/Rocky/RHEL (Fedora ships it directly).
  # shellcheck disable=SC1091
  if [ "$(. /etc/os-release; echo "$ID")" != fedora ]; then
    dnf install -y -q epel-release || die "couldn't enable EPEL. On RHEL proper: sudo subscription-manager repos --enable codeready-builder-for-rhel-9-\$(arch)-rpms && sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
  fi
  dnf install -y -q curl ca-certificates git sudo openssh-server firewalld fail2ban \
    dnf-automatic python3 rsync policycoreutils-python-utils
  systemctl enable --now firewalld
fi
ok "packages installed"

log "Timezone: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true || warn "could not enable NTP; check 'timedatectl'"
ok "time is $(date)"

log "Admin user: $ADMIN_USER"
if id "$ADMIN_USER" >/dev/null 2>&1; then
  ok "$ADMIN_USER already exists"
else
  useradd -m -s /bin/bash "$ADMIN_USER"
  ok "created $ADMIN_USER"
fi
admin_group=sudo; [ "$OS_FAMILY" = rhel ] && admin_group=wheel
usermod -aG "$admin_group" "$ADMIN_USER"
ok "$ADMIN_USER is in $admin_group (sudo asks for a password: set one next)"

home_dir=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
auth="$home_dir/.ssh/authorized_keys"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home_dir/.ssh"
touch "$auth"

# The key comes from one of: PUBKEY env var, the file named in playbook.env
# (if you copied it to the server), or root's own authorized_keys (the key your
# VPS or installer already put there).
key="${PUBKEY:-}"
pub_file="${SSH_PUBKEY_FILE:-}"; pub_file="${pub_file/#\~/$HOME}"
if [ -z "$key" ] && [ -f "$pub_file" ]; then key=$(cat "$pub_file"); fi
if [ -z "$key" ] && [ -s /root/.ssh/authorized_keys ]; then key=$(cat /root/.ssh/authorized_keys); fi
if [ -z "$key" ] && [ -s "$auth" ]; then
  key=$(cat "$auth")   # the installer (e.g. Ubuntu's "import SSH key") already put it there
fi
[ -n "$key" ] || die "no SSH public key found. Re-run with PUBKEY='ssh-ed25519 AAAA... you@laptop'"

printf '%s\n' "$key" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -qxF "$line" "$auth" || printf '%s\n' "$line" >> "$auth"
done
chown "$ADMIN_USER:$ADMIN_USER" "$auth"; chmod 600 "$auth"
ok "$(grep -c . "$auth") key(s) in $auth"

if ! passwd -S "$ADMIN_USER" 2>/dev/null | grep -cE ' (P|PS) ' >/dev/null; then
  warn "$ADMIN_USER has no password yet. sudo needs one. Set it now:"
  if [ -t 0 ]; then passwd "$ADMIN_USER"; else warn "run: sudo passwd $ADMIN_USER"; fi
fi

install -d -m 755 /srv/sites /srv/cloudflared
install -d -m 700 /etc/homelab-playbook
ok "created /srv/sites, /srv/cloudflared, /etc/homelab-playbook"

cat <<EOF

Next, BEFORE closing this session, open a SECOND terminal on your laptop and prove
the key works:   ssh $ADMIN_USER@<server>   then   sudo -v
Only when that works, run: sudo ./scripts/server/10-harden-ssh.sh
EOF
