#!/usr/bin/env bash
# Read-only security audit. Changes nothing. Run any time, and after every phase:
#   sudo ./scripts/server/audit.sh
#
# Every line is PASS, WARN or FAIL, and each check is written so it CAN fail:
# a check that only ever says PASS is decoration, not a control.
# Exit code: number of FAILs (0 means clean).
set -uo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
detect_os
fails=0; warns=0
P() { printf '  PASS %s\n' "$*"; }
W() { printf '  WARN %s\n' "$*"; warns=$((warns + 1)); }
F() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

echo "== SSH (effective config from sshd -T, not the file)"
eff=$(sshd -T 2>/dev/null || true)
[ -n "$eff" ] || F "sshd -T returned nothing; is sshd installed?"
for pair in "passwordauthentication no" "permitrootlogin no" "pubkeyauthentication yes" "kbdinteractiveauthentication no"; do
  if printf '%s\n' "$eff" | grep -x "$pair" >/dev/null; then P "$pair"; else F "expected '$pair'"; fi
done

echo "== Firewall"
if [ "$OS_FAMILY" = debian ]; then
  st=$(ufw status verbose 2>/dev/null || true)
  if printf '%s' "$st" | grep 'Status: active' >/dev/null; then P "ufw active"; else F "ufw is not active"; fi
  if printf '%s' "$st" | grep 'deny (incoming)' >/dev/null; then P "default deny incoming"; else F "default incoming policy is not deny"; fi
  if printf '%s' "$st" | grep -E '^(80|443)(/tcp)? .*ALLOW' >/dev/null; then W "80/443 open; with a tunnel you don't need them"; fi
else
  if systemctl is-active --quiet firewalld; then P "firewalld active"; else F "firewalld is not active"; fi
fi

echo "== fail2ban"
if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
  P "sshd jail running ($(fail2ban-client status sshd | sed -n 's/.*Currently banned:[[:space:]]*//p') banned now)"
else F "fail2ban sshd jail not running"; fi

echo "== Automatic updates"
if [ "$OS_FAMILY" = debian ]; then
  if systemctl is-enabled --quiet apt-daily-upgrade.timer && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
  then P "unattended-upgrades enabled"; else F "unattended-upgrades not enabled"; fi
  n=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)
  if [ "${n:-0}" -eq 0 ]; then P "no pending package updates"
  else W "$n package updates pending (third-party repos aren't auto-patched: sudo apt upgrade)"; fi
else
  if systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null || systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null
  then P "dnf automatic enabled"; else F "dnf automatic not enabled"; fi
fi
if systemctl is-enabled --quiet homelab-reboot-check.timer 2>/dev/null; then P "reboot check scheduled"; else F "homelab-reboot-check.timer not enabled"; fi
if [ -f /var/run/reboot-required ]; then W "a reboot is pending (it happens at the scheduled time)"; fi
if [ -s /etc/homelab-playbook/notify.env ]; then P "notifications configured"; else W "no NOTIFY_URL; you won't hear about failures"; fi

echo "== sudo"
if grep -rhs '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/ | grep -v '^Defaults' >/dev/null; then
  W "NOPASSWD sudo rule present: $(grep -rls '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/ | tr '\n' ' ')"
else P "sudo requires a password"; fi

echo "== Listening ports"
# Anything listening on a non-loopback address is reachable from your LAN at
# least. Expected: only sshd. cloudflared listens on nothing.
exposed=$(ss -ltnpH 2>/dev/null | awk '{print $4, $6}' | grep -vE '^(127\.|\[::1\]|::1)' || true)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *sshd*) P "ssh: ${line%% *}" ;; *) W "listening beyond loopback: $line" ;; esac
done <<EOF
$exposed
EOF

if command -v docker >/dev/null 2>&1; then
  echo "== Docker"
  pub=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:|:::' || true)
  if [ -n "$pub" ]; then
    F "containers published on ALL interfaces (Docker bypasses the firewall for these): $(printf '%s' "$pub" | tr '\n' ';')"
  else P "no container published beyond 127.0.0.1"; fi
  unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}')
  if [ -z "$unhealthy" ]; then P "no unhealthy containers"; else F "unhealthy: $unhealthy"; fi
fi

echo "== Secret files"
found=0
for f in /srv/cloudflared/*/.env /srv/sites/*/.env /etc/homelab-playbook/*.env; do
  [ -e "$f" ] || continue; found=1
  m=$(stat -c '%a' "$f")
  case "$m" in 600|400) P "$f is $m" ;; *) F "$f is mode $m (should be 600)" ;; esac
done
[ "$found" -eq 1 ] || P "no secret files to check yet"

echo "== Disk"
use=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ "$use" -ge 90 ]; then F "root filesystem ${use}% full"
elif [ "$use" -ge 80 ]; then W "root filesystem ${use}% full"
else P "root filesystem ${use}% used"; fi

echo
echo "audit: $fails fail, $warns warn"
exit "$fails"
