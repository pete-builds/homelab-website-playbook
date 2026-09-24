#!/usr/bin/env bash
# Runs INSIDE a throwaway Debian/Ubuntu container (see tests/run-linux-checks.sh).
# Validates the server templates with the real daemons' own config checkers.
# It cannot test anything that needs systemd, a kernel, or a network edge;
# those are verified on a real server by scripts/server/audit.sh.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq openssh-server fail2ban unattended-upgrades python3 >/dev/null 2>&1

# shellcheck source=../../scripts/lib.sh
. /repo/scripts/lib.sh
export PLAYBOOK_ROOT=/repo
pass=0; failn=0
t_ok()  { echo "  OK   $*"; pass=$((pass + 1)); }
t_bad() { echo "  FAIL $*"; failn=$((failn + 1)); }
. /etc/os-release
echo "== $PRETTY_NAME"

# ── sshd: our drop-in parses and WINS over cloud-init's ──────────────────────
mkdir -p /run/sshd /etc/ssh/sshd_config.d
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config && t_ok "sshd_config includes sshd_config.d" || t_bad "no Include line"
ssh-keygen -A >/dev/null 2>&1
id admin >/dev/null 2>&1 || useradd -m admin
export SSH_PORT=2222 ADMIN_USER=admin
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
render_template /repo/templates/ssh/00-homelab-playbook.conf /etc/ssh/sshd_config.d/00-homelab-playbook.conf
if sshd -t; then t_ok "sshd -t accepts the drop-in"; else t_bad "sshd -t rejected the drop-in"; fi
eff=$(sshd -T)
for pair in "port 2222" "permitrootlogin no" "passwordauthentication no" "pubkeyauthentication yes" "maxauthtries 3" "allowusers admin" "kbdinteractiveauthentication no"; do
  grep -qx "$pair" <<<"$eff" && t_ok "effective: $pair" || t_bad "effective config lacks '$pair'"
done
# Control: the same file named 99-* must LOSE to 50-cloud-init.conf. If this
# passed too, the check above couldn't tell a winning file from a losing one.
mv /etc/ssh/sshd_config.d/00-homelab-playbook.conf /etc/ssh/sshd_config.d/99-homelab-playbook.conf
eff2=$(sshd -T); grep -qx "passwordauthentication yes" <<<"$eff2" \
  && t_ok "control: a 99-* name loses to cloud-init (so 00-* is load-bearing)" \
  || t_bad "control: 99-* still won; the ordering test proves nothing"
rm -f /etc/ssh/sshd_config.d/*.conf

# ── fail2ban: jail.local parses ──────────────────────────────────────────────
export LAN_CIDR_OR_LOOPBACK=192.168.1.0/24 BANACTION=ufw
render_template /repo/templates/fail2ban/jail.local /etc/fail2ban/jail.local
touch /var/log/fail2ban.log /var/log/auth.log
if fail2ban-client -t >/dev/null 2>&1; then t_ok "fail2ban-client -t accepts jail.local"; else fail2ban-client -t || true; t_bad "fail2ban rejected jail.local"; fi
# Control: a broken jail must be rejected, or the check above is decoration.
# ("enabled = maybe" is NOT a valid control: fail2ban quietly reads it as false.)
printf '[broken]\nenabled = true\nfilter = no-such-filter-xyz\nlogpath = /var/log/auth.log\n' > /etc/fail2ban/jail.d/zz-broken.local
if fail2ban-client -t >/dev/null 2>&1; then t_bad "control: fail2ban accepted a broken jail"; else t_ok "control: fail2ban rejects a broken jail"; fi
rm -f /etc/fail2ban/jail.d/zz-broken.local

# ── unattended-upgrades: our origins parse and match the security pocket ─────
sed -n '/^cat > \/etc\/apt\/apt.conf.d\/52homelab-playbook/,/^EOF$/p' /repo/scripts/server/60-auto-updates.sh | sed '1d;$d' \
  > /etc/apt/apt.conf.d/52homelab-playbook
# apt-config parses every file in apt.conf.d and exits non-zero on a syntax error.
if apt-config dump >/dev/null 2>&1; then t_ok "apt accepts 52homelab-playbook"; else t_bad "apt rejects 52homelab-playbook"; fi
# Control: a deliberately broken file must make apt-config fail.
printf 'Unattended-Upgrade::Origins-Pattern {\n  "origin=x"\n' > /etc/apt/apt.conf.d/99zz-broken
if apt-config dump >/dev/null 2>&1; then t_bad "control: apt accepted a broken file"; else t_ok "control: apt rejects a broken file"; fi
rm -f /etc/apt/apt.conf.d/99zz-broken
out=$(unattended-upgrade --dry-run --debug 2>&1 || true)
if grep -q 'Allowed origins are:.*security' <<<"$out"; then t_ok "unattended-upgrades allows the security pocket"
else printf '%s\n' "$out" | head -20; t_bad "unattended-upgrades did not load security origins"; fi
# Real failures start a line; "ErrorText: ''" inside a debug dump is not one.
if grep -qE '^(ERROR|E:|Traceback)' <<<"$out"; then grep -E '^(ERROR|E:|Traceback)' <<<"$out" | head -5; t_bad "unattended-upgrades reported an error"; else t_ok "unattended-upgrades dry run clean"; fi

# ── sysctl file: every line is key = value ───────────────────────────────────
bad=$(grep -vE '^\s*(#|$)' /repo/templates/sysctl/99-homelab-playbook.conf | grep -vE '^[a-z0-9_.]+ = [0-9]+$' || true)
[ -z "$bad" ] && t_ok "sysctl file is well formed" || t_bad "malformed sysctl lines: $bad"

# ── notify helper escapes JSON for Discord ───────────────────────────────────
esc=$(printf '%s' 'say "hi" \ now' | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"content":"%s"}' "$esc" | python3 -c 'import json,sys; json.load(sys.stdin)' && t_ok "notify JSON escaping is valid" || t_bad "notify JSON escaping broke"

echo "== $PRETTY_NAME: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
