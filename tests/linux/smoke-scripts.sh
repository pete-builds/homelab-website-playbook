#!/usr/bin/env bash
# Runs INSIDE a throwaway Debian/Ubuntu container with NET_ADMIN.
# Executes the real server scripts, with only systemctl and timedatectl stubbed
# (containers have no systemd), and then runs audit.sh to check the result.
# Catches script bugs: unset variables, bad paths, broken idempotency.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Stubs for the two things a container can't do. They log what they were asked,
# so the test can assert the scripts asked for the right things.
mkdir -p /stub
cat > /stub/systemctl <<'EOF'
#!/bin/sh
echo "systemctl $*" >> /tmp/systemctl.log
case "$*" in
  *is-active*fail2ban*) exit 0 ;;
  *is-enabled*) exit 0 ;;
  *is-active*ssh.socket*) exit 1 ;;
  *list-unit-files*ssh.service*) exit 0 ;;
  *restart*fail2ban*) fail2ban-server -b >/dev/null 2>&1 || true; exit 0 ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "timedatectl $*" >> /tmp/systemctl.log\n' > /stub/timedatectl
chmod +x /stub/*
export PATH="/stub:$PATH"

cp -R /repo /work && cd /work
cat > playbook.env <<'EOF'
ADMIN_USER=friend
SSH_PORT=22
LAN_CIDR=192.168.1.0/24
TIMEZONE=UTC
REBOOT_TIME=04:30
EOF
mkdir -p /root/.ssh && echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLYFORCI test@ci" > /root/.ssh/authorized_keys
mkdir -p /run/sshd

pass=0; failn=0
t_ok()  { echo "  OK   $*"; pass=$((pass + 1)); }
t_bad() { echo "  FAIL $*"; failn=$((failn + 1)); }
run() { if "$@" > /tmp/out.log 2>&1; then t_ok "$*"; else t_bad "$* (exit $?)"; tail -15 /tmp/out.log; fi; }

run ./scripts/server/00-bootstrap.sh
id friend >/dev/null 2>&1 && t_ok "admin user exists" || t_bad "admin user missing"
grep -q TESTKEYONLYFORCI /home/friend/.ssh/authorized_keys && t_ok "key installed" || t_bad "key not installed"
[ "$(stat -c %a /home/friend/.ssh/authorized_keys)" = 600 ] && t_ok "authorized_keys is 600" || t_bad "authorized_keys mode"
run ./scripts/server/00-bootstrap.sh
[ "$(grep -c TESTKEYONLYFORCI /home/friend/.ssh/authorized_keys)" = 1 ] && t_ok "re-run did not duplicate the key" || t_bad "key duplicated on re-run"

ASSUME_YES=1 run ./scripts/server/10-harden-ssh.sh
sshd_eff=$(sshd -T); grep -qx 'passwordauthentication no' <<<"$sshd_eff" && t_ok "sshd effective: no passwords" || t_bad "passwords still allowed"

run ./scripts/server/20-firewall.sh
ufw_st=$(ufw status); grep -q 'Status: active' <<<"$ufw_st" && t_ok "ufw active" || t_bad "ufw not active"
grep -q '192.168.1.0/24' <<<"$ufw_st" && t_ok "ssh restricted to LAN_CIDR" || t_bad "ssh rule missing LAN restriction"

run ./scripts/server/30-fail2ban.sh
run ./scripts/server/40-kernel.sh

# Positive and negative control for the audit: it must FAIL here, because the
# updates phase hasn't run and so its timers/config don't exist yet...
# (Ubuntu's unattended-upgrades package writes 20auto-upgrades itself, so remove it
# to get a real "not configured" starting point; otherwise this control can't fail.)
rm -f /etc/apt/apt.conf.d/20auto-upgrades
./scripts/server/audit.sh > /tmp/audit1.log 2>&1 || true
grep -q 'FAIL unattended-upgrades not enabled' /tmp/audit1.log \
  && t_ok "control: audit FAILs before auto-updates are configured" \
  || { t_bad "control: audit did not notice missing auto-updates"; cat /tmp/audit1.log; }
run ./scripts/server/60-auto-updates.sh
[ -x /usr/local/sbin/homelab-reboot-if-needed ] && t_ok "reboot helper installed" || t_bad "reboot helper missing"
grep -q 'OnCalendar=\*-\*-\* 04:30:00' /etc/systemd/system/homelab-reboot-check.timer && t_ok "reboot timer at REBOOT_TIME" || t_bad "reboot timer wrong"
grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && t_ok "unattended-upgrades on" || t_bad "unattended-upgrades off"
# ...and the auto-updates FAIL must be gone afterwards.
./scripts/server/audit.sh > /tmp/audit2.log 2>&1 || true
if grep -q 'FAIL unattended-upgrades' /tmp/audit2.log; then t_bad "audit still FAILs updates after 60-auto-updates.sh"; else t_ok "audit passes updates after 60-auto-updates.sh"; fi
grep -E '^  (PASS|FAIL|WARN)' /tmp/audit2.log | sed 's/^/        audit: /'

. /etc/os-release
echo "== smoke $PRETTY_NAME: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
