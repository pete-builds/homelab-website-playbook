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
  # Right after a fresh install, apt-daily is often holding the package lock:
  # wait for it instead of dying. NEEDRESTART_MODE=a: restart services without
  # the full-screen question needrestart otherwise asks mid-install.
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  APT_LOCK="-o DPkg::Lock::Timeout=600"
  # shellcheck disable=SC2086
  run_quiet "apt-get update" apt-get $APT_LOCK update -q
  # shellcheck disable=SC2086
  run_quiet "install base packages" apt-get $APT_LOCK install -y -q curl ca-certificates git sudo openssh-server ufw fail2ban \
    unattended-upgrades apt-listchanges needrestart python3 rsync iproute2
else
  # fail2ban lives in EPEL on Alma/Rocky/RHEL (Fedora ships it directly).
  # shellcheck disable=SC1091
  if [ "$(. /etc/os-release; echo "$ID")" != fedora ]; then
    dnf install -y -q epel-release || die "couldn't enable EPEL. On RHEL proper: sudo subscription-manager repos --enable codeready-builder-for-rhel-9-\$(arch)-rpms && sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
  fi
  run_quiet "install base packages" dnf install -y -q curl ca-certificates git sudo openssh-server firewalld fail2ban \
    dnf-automatic python3 rsync policycoreutils-python-utils iproute
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

# The key comes from one of: PUBKEY, laptop.pub (./playbook server sync puts
# your laptop's public key next to this playbook), root's own authorized_keys
# (the key a VPS or installer put there), or the admin user's own (Ubuntu's
# "import SSH key" puts it there). SSH_PUBKEY_FILE names a file on your LAPTOP,
# so it means nothing here, under sudo.
key="${PUBKEY:-}"
if [ -z "$key" ] && [ -s "$PLAYBOOK_ROOT/laptop.pub" ]; then key=$(cat "$PLAYBOOK_ROOT/laptop.pub"); fi
if [ -z "$key" ] && [ -s /root/.ssh/authorized_keys ]; then key=$(cat /root/.ssh/authorized_keys); fi
if [ -z "$key" ] && [ -s "$auth" ]; then key=$(cat "$auth"); fi
[ -n "$key" ] || die "no SSH public key found. From the laptop: ./playbook server key"

# Only plain key lines. Cloud images put lines like
#   no-port-forwarding,command="echo 'Please login as ubuntu'" ssh-ed25519 ...
# in root's file; copied as they are, your user could log in but never get a shell.
added=0
printf '%s\n' "$key" | grep -E '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) ' > "$auth.new" || true
[ -s "$auth.new" ] || { rm -f "$auth.new"; die "found SSH keys, but none as a plain key line (they all carry options). From the laptop: ./playbook server key"; }
while IFS= read -r line; do
  grep -qxF "$line" "$auth" || { printf '%s\n' "$line" >> "$auth"; added=$((added + 1)); }
done < "$auth.new"
rm -f "$auth.new"
chown "$ADMIN_USER:$ADMIN_USER" "$auth"; chmod 600 "$auth"
ok "$(grep -c . "$auth") key(s) in $auth ($added new)"

if ! passwd -S "$ADMIN_USER" 2>/dev/null | grep -cE ' (P|PS) ' >/dev/null; then
  warn "$ADMIN_USER has no password yet. sudo needs one. Set it now:"
  if [ -t 0 ]; then passwd "$ADMIN_USER"; else warn "run: sudo passwd $ADMIN_USER"; fi
fi

install -d -m 755 /srv/sites /srv/cloudflared
install -d -m 700 /etc/homelab-playbook
ok "created /srv/sites, /srv/cloudflared, /etc/homelab-playbook"

cat <<EOF

Next, from the laptop: ./playbook server ssh
(It turns passwords off, with a safety net: have a second terminal ready.)
EOF
