#!/usr/bin/env bash
# Runs INSIDE a throwaway Debian/Ubuntu container with NET_ADMIN.
# Executes the real server scripts, with only systemctl and timedatectl stubbed
# (containers have no systemd), and then runs audit.sh to check the result.
# Catches script bugs: unset variables, bad paths, broken idempotency.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Stubs for the things a container can't do. systemctl REMEMBERS what was
# enabled, so an audit check for "is this timer enabled" can fail here the way
# it would on a real server (a stub that says yes to everything would make
# every such check pass by construction).
mkdir -p /stub
cat > /stub/systemctl <<'EOF'
#!/bin/sh
echo "systemctl $*" >> /tmp/systemctl.log
st=/tmp/systemd-enabled; touch "$st"
args=""; for a in "$@"; do case "$a" in -*) ;; *) args="$args $a" ;; esac; done
# shellcheck disable=SC2086
set -- $args
verb=${1:-}; [ $# -gt 0 ] && shift
case "$verb" in
  enable)  for u in "$@"; do grep -qx "$u" "$st" || echo "$u" >> "$st"; done ;;
  disable) for u in "$@"; do grep -vx "$u" "$st" > "$st.t" || true; mv "$st.t" "$st"; done ;;
  is-enabled) if grep -qx "$1" "$st"; then echo enabled; else echo disabled; exit 1; fi ;;
  is-active)
    case "$1" in
      fail2ban) fail2ban-client ping >/dev/null 2>&1 ;;
      ssh.socket) exit 1 ;;
      *) grep -qx "$1" "$st" ;;
    esac ;;
  list-unit-files)
    for u in "$@"; do
      [ -f "/etc/systemd/system/$u" ] || [ -f "/lib/systemd/system/$u" ] || [ -f "/usr/lib/systemd/system/$u" ] || exit 1
    done ;;
  restart) case "${1:-}" in fail2ban) fail2ban-server -b >/dev/null 2>&1 || true ;; esac ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "timedatectl $*" >> /tmp/systemctl.log\n' > /stub/timedatectl
printf '#!/bin/sh\necho "systemd-run $*" >> /tmp/systemctl.log\n' > /stub/systemd-run
chmod +x /stub/*
export PATH="/stub:$PATH"

cp -R /repo /work && cd /work
cat > playbook.env <<'EOF'
ADMIN_USER=friend
SSH_PORT=22
LAN_CIDR=192.168.1.0/24
TIMEZONE=UTC
REBOOT_TIME=04:30
SITE_NAME=mysite
SITE_PORT=8080
DOMAIN=example.org
SITE_MARKER="Hello from the smoke test"
EOF
# Root's file as a cloud image writes it: a forced-command line that must NOT
# be copied, and a plain key that must be.
mkdir -p /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF'
no-port-forwarding,command="echo 'Please login as the user ubuntu rather than root.';sleep 10" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFORCEDCOMMANDKEY cloud
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLYFORCI test@ci
EOF
mkdir -p /run/sshd

pass=0; failn=0
t_ok()  { echo "  OK   $*"; pass=$((pass + 1)); }
t_bad() { echo "  FAIL $*"; failn=$((failn + 1)); }
run() { if "$@" > /tmp/out.log 2>&1; then t_ok "$*"; else t_bad "$* (exit $?)"; tail -15 /tmp/out.log; fi; }

run ./scripts/server/00-bootstrap.sh
id friend >/dev/null 2>&1 && t_ok "admin user exists" || t_bad "admin user missing"
grep -q TESTKEYONLYFORCI /home/friend/.ssh/authorized_keys && t_ok "key installed" || t_bad "key not installed"
grep -q 'command=' /home/friend/.ssh/authorized_keys && t_bad "a forced-command line was copied (no shell for the admin)" || t_ok "forced-command lines from root's file are left out"
[ "$(stat -c %a /home/friend/.ssh/authorized_keys)" = 600 ] && t_ok "authorized_keys is 600" || t_bad "authorized_keys mode"
run ./scripts/server/00-bootstrap.sh
[ "$(grep -c TESTKEYONLYFORCI /home/friend/.ssh/authorized_keys)" = 1 ] && t_ok "re-run did not duplicate the key" || t_bad "key duplicated on re-run"

# Without a terminal (and without ASSUME_YES) it must arm the revert timer, then
# revert and fail, never leave an unconfirmed change in place.
if ./scripts/server/10-harden-ssh.sh </dev/null >/tmp/h.log 2>&1; then t_bad "no-tty harden exited 0"; else t_ok "no-tty harden refuses to keep the change"; fi
grep -q 'systemd-run.*--on-active=300' /tmp/systemctl.log && t_ok "revert timer armed before sshd restart" || t_bad "revert timer not armed"
[ ! -f /etc/ssh/sshd_config.d/00-homelab-playbook.conf ] && t_ok "unconfirmed drop-in was reverted" || t_bad "unconfirmed drop-in left in place"
ASSUME_YES=1 run ./scripts/server/10-harden-ssh.sh
sshd_eff=$(sshd -T); grep -qx 'passwordauthentication no' <<<"$sshd_eff" && t_ok "sshd effective: no passwords" || t_bad "passwords still allowed"

# ── The LAN_CIDR lockout guard, the way people actually run it: through sudo,
# which wipes SSH_CLIENT. A REAL sshd, a REAL session from outside LAN_CIDR:
# the firewall step must find it anyway and refuse.
for a in 10.9.9.9 192.168.1.5 192.168.1.23; do ip addr add "$a/32" dev lo 2>/dev/null || true; done
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/smoke
cat /root/.ssh/smoke.pub >> /home/friend/.ssh/authorized_keys
/usr/sbin/sshd
S="-i /root/.ssh/smoke -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR"
# shellcheck disable=SC2086
ssh $S -b 10.9.9.9 friend@192.168.1.5 'sleep 40' </dev/null & outside=$!
sleep 2
# shellcheck disable=SC2024  # the log is ours to write; sudo only runs the script
if SSH_CLIENT="" sudo ./scripts/server/20-firewall.sh >/tmp/fw.log 2>&1; then t_bad "under sudo, the firewall accepted a LAN_CIDR that excludes an open session"; cat /tmp/fw.log
else grep -q 'OUTSIDE LAN_CIDR' /tmp/fw.log && t_ok "under sudo, a real session from 10.9.9.9 (outside LAN_CIDR) is found and refused" || { t_bad "firewall failed for another reason"; cat /tmp/fw.log; }; fi
kill "$outside" 2>/dev/null || true; wait "$outside" 2>/dev/null || true
# shellcheck disable=SC2086
ssh $S -b 192.168.1.23 friend@192.168.1.5 'sleep 40' </dev/null & inside=$!
sleep 2
# shellcheck disable=SC2024
if sudo ./scripts/server/20-firewall.sh >/tmp/fw2.log 2>&1 && grep -q 'every SSH session (192.168.1.23) is inside' /tmp/fw2.log; then
  t_ok "under sudo, a session from inside LAN_CIDR is recognised and the firewall applies"
else t_bad "firewall with an inside session"; cat /tmp/fw2.log; fi
kill "$inside" 2>/dev/null || true; wait "$inside" 2>/dev/null || true
ufw_st=$(ufw status); grep -q 'Status: active' <<<"$ufw_st" && t_ok "ufw active" || t_bad "ufw not active"
grep -q '192.168.1.0/24' <<<"$ufw_st" && t_ok "ssh restricted to LAN_CIDR" || t_bad "ssh rule missing LAN restriction"

run ./scripts/server/30-fail2ban.sh
run ./scripts/server/40-kernel.sh
[ -f /etc/sysctl.d/99-homelab-playbook.conf ] && t_ok "kernel settings file installed" || t_bad "no sysctl drop-in"

# Positive and negative control for the audit: it must FAIL here, because the
# updates phase hasn't run and so its timers/config don't exist yet...
# (Ubuntu's unattended-upgrades package writes 20auto-upgrades itself, so remove it
# to get a real "not configured" starting point; otherwise this control can't fail.)
rm -f /etc/apt/apt.conf.d/20auto-upgrades
./scripts/server/audit.sh > /tmp/audit1.log 2>&1 || true
grep -q 'FAIL unattended-upgrades not enabled' /tmp/audit1.log \
  && t_ok "control: audit FAILs before auto-updates are configured" \
  || { t_bad "control: audit did not notice missing auto-updates"; cat /tmp/audit1.log; }
grep -q 'FAIL homelab-reboot-check.timer not enabled' /tmp/audit1.log \
  && t_ok "control: audit FAILs a timer that isn't enabled (the stub remembers)" \
  || t_bad "control: audit passed a timer nobody enabled"
run ./scripts/server/60-auto-updates.sh
[ -x /usr/local/sbin/homelab-reboot-if-needed ] && t_ok "reboot helper installed" || t_bad "reboot helper missing"
grep -q 'OnCalendar=\*-\*-\* 04:30:00' /etc/systemd/system/homelab-reboot-check.timer && t_ok "reboot timer at REBOOT_TIME" || t_bad "reboot timer wrong"
grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && t_ok "unattended-upgrades on" || t_bad "unattended-upgrades off"
grep -q 'OnFailure=homelab-alert@%n.service' /etc/systemd/system/apt-daily-upgrade.service.d/homelab-alert.conf \
  && t_ok "a failed update run alerts (OnFailure drop-in)" || t_bad "no OnFailure drop-in on apt-daily-upgrade"
grep -q 'homelab-watch --boot' /etc/systemd/system/homelab-booted.service && t_ok "after a reboot: a health verdict" || t_bad "booted unit has no verdict"

# The staleness check: an update that last SUCCEEDED 10 days ago is a FAIL; a
# fresh one isn't. (A failed unattended-upgrade exits 0, so only this catches it.)
mkdir -p /var/lib/apt/periodic
touch -d '10 days ago' /var/lib/apt/periodic/upgrade-stamp
./scripts/server/audit.sh > /tmp/audit2.log 2>&1 || true
grep -q "FAIL security updates haven't succeeded" /tmp/audit2.log && t_ok "audit FAILs updates that stopped succeeding 10 days ago" || t_bad "stale updates not caught"
touch /var/lib/apt/periodic/upgrade-stamp
./scripts/server/audit.sh > /tmp/audit2.log 2>&1 || true
if grep -q 'FAIL unattended-upgrades\|FAIL security updates' /tmp/audit2.log; then t_bad "audit still FAILs updates after 60-auto-updates.sh"; cat /tmp/audit2.log
else t_ok "audit passes updates after 60-auto-updates.sh"; fi
grep -E '^  (PASS|FAIL|WARN)' /tmp/audit2.log | sed 's/^/        audit: /'

# ── probe.sh: what `./playbook status` reads, as the admin user, no sudo.
runuser -u friend -- bash /work/scripts/server/probe.sh mysite 8080 > /tmp/probe.txt 2>&1 || true
for kv in bootstrapped=yes step_ssh=yes step_firewall=yes step_fail2ban=yes step_kernel=yes step_updates=yes site_healthz=000 timer_watch=disabled; do
  grep -qx "$kv" /tmp/probe.txt && t_ok "probe: $kv" || { t_bad "probe: expected $kv"; cat /tmp/probe.txt; }
done

# ── homelab-notify, the real one: Discord JSON must survive quotes and backslashes.
mkdir -p /stub2
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -d ] && printf "%%s" "$2" > /tmp/notify-body; shift; done\n' > /stub2/curl
chmod +x /stub2/curl
printf 'NOTIFY_URL=https://discord.com/api/webhooks/1/x\n' > /etc/homelab-playbook/notify.env
PATH="/stub2:$PATH" /usr/local/sbin/homelab-notify 'say "hi" \ now'
python3 -c 'import json; m=json.load(open("/tmp/notify-body"))["content"]; assert m.endswith("say \"hi\" \\ now"), m' \
  && t_ok "homelab-notify sends valid Discord JSON (quotes, backslash)" || t_bad "homelab-notify JSON broke: $(cat /tmp/notify-body)"
rm -f /etc/homelab-playbook/notify.env   # later steps must not post to a real webhook

# ── 90-watch: installs root-owned copies, the site conf, the timers. Its first
# check must FAIL here (no site, no tunnel in this container), and it must say so.
mkdir -p /stub3; printf '#!/bin/sh\nexit 1\n' > /stub3/docker; chmod +x /stub3/docker
if PATH="/stub3:$PATH" ./scripts/server/90-watch.sh </dev/null >/tmp/w.log 2>&1; then t_bad "90-watch passed with no site running"
else grep -q 'first check FAILED' /tmp/w.log && t_ok "90-watch installs, runs, and reports its failing first check" || { t_bad "90-watch failed early"; tail -20 /tmp/w.log; }; fi
[ "$(stat -c '%U %a' /usr/local/lib/homelab-playbook/scripts/server/site-deploy.sh)" = "root 755" ] && t_ok "installed copies are root-owned" || t_bad "installed copy ownership"
[ "$(stat -c %a /etc/homelab-playbook/sites/mysite.conf)" = 600 ] && t_ok "site conf is 600" || t_bad "site conf mode"
systemctl is-enabled homelab-watch.timer >/dev/null && t_ok "watch timer enabled" || t_bad "watch timer not enabled"
systemctl is-enabled homelab-autodeploy.timer >/dev/null && t_bad "auto-deploy on without AUTO_DEPLOY=yes" || t_ok "auto-deploy stays off by default"
[ -s /var/lib/homelab-playbook/audit.txt ] && [ "$(stat -c %a /var/lib/homelab-playbook/audit.txt)" = 644 ] && t_ok "audit result readable without sudo" || t_bad "no readable audit.txt"
echo 'AUTO_DEPLOY=yes' >> playbook.env
PATH="/stub3:$PATH" ./scripts/server/90-watch.sh </dev/null >/tmp/w2.log 2>&1 || true
systemctl is-enabled homelab-autodeploy.timer >/dev/null && t_ok "AUTO_DEPLOY=yes turns auto-deploy on" || t_bad "AUTO_DEPLOY=yes ignored"

bash /work/tests/linux/watch-machine.sh || failn=$((failn + 1))

. /etc/os-release
echo "== smoke $PRETTY_NAME: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
