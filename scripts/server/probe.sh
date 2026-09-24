#!/usr/bin/env bash
# Read-only facts about this server, one KEY=value per line, for
# `./playbook status` on the laptop. No sudo, no changes, nothing secret:
# it reads file presence, public config, loopback HTTP, and the results the
# root-run watch and audit leave in /var/lib/homelab-playbook.
#
#   probe.sh <site> <port> [metrics-port]
#
# The laptop pipes this file over ssh, so it works before the playbook is even
# on the server.
set -u
site=${1:-}; port=${2:-0}; mport=${3:-20241}
kv() { printf '%s=%s\n' "$1" "$2"; }
yes_no() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
# curl already prints 000 when nothing answers; `|| echo 000` would make it 000000.
code() { local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null); echo "${c:-000}"; }

# shellcheck disable=SC1091
os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
kv os "${os:-unknown}"
kv user "$(id -un)"
kv playbook "$(yes_no test -f "$HOME/homelab-website-playbook/scripts/lib.sh")"
kv bootstrapped "$(yes_no test -d /srv/sites)"
kv sudo_group "$(yes_no sh -c 'id -Gn | tr " " "\n" | grep -qxE "sudo|wheel"')"

# Phase 2, step by step. These are the files each step leaves behind, readable
# without root. They say the step RAN; the audit says it's still effective.
kv step_ssh "$(yes_no test -f /etc/ssh/sshd_config.d/00-homelab-playbook.conf)"
if [ -r /etc/ufw/ufw.conf ]; then kv step_firewall "$(yes_no grep -q '^ENABLED=yes' /etc/ufw/ufw.conf)"
else kv step_firewall "$(yes_no systemctl is-active --quiet firewalld)"; fi
kv step_fail2ban "$(yes_no test -f /etc/fail2ban/jail.local)"
kv step_kernel "$(yes_no test -f /etc/sysctl.d/99-homelab-playbook.conf)"
kv step_docker "$(yes_no test -f /etc/docker/daemon.json)"
kv step_updates "$(yes_no test -x /usr/local/sbin/homelab-reboot-if-needed)"
kv docker_access "$(yes_no docker info)"
kv reboot_pending "$(yes_no test -f /var/run/reboot-required)"
kv disk_pct "$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"

# The site and the tunnel.
if [ -n "$site" ]; then
  kv site_checkout "$(yes_no test -d "/srv/sites/$site/.git")"
  kv site_head "$(git -C "/srv/sites/$site" rev-parse --short=12 HEAD 2>/dev/null)"
  kv site_healthz "$(code "http://127.0.0.1:$port/healthz")"
  kv site_build "$(curl -s --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null | sed -n 's/.*name="build" content="build:\([^"]*\)".*/\1/p' | head -n 1)"
  kv tunnel_installed "$(yes_no test -f "/srv/cloudflared/$site/docker-compose.yml")"
  kv tunnel_ready "$(code "http://127.0.0.1:$mport/ready")"
  kv autodeploy_paused "$(yes_no test -f "/srv/sites/.state/$site/paused")"
fi

# What the root-run timers concluded, and when.
for t in watch audit autodeploy; do
  # is-enabled prints "disabled" AND exits 1, so no `|| echo`: only an empty
  # answer (no such unit) means none.
  v=$(systemctl is-enabled "homelab-$t.timer" 2>/dev/null)
  kv "timer_$t" "${v:-none}"
done
if [ -r /var/lib/homelab-playbook/watch.txt ]; then
  kv watch_at "$(stat -c %Y /var/lib/homelab-playbook/watch.txt)"
  kv watch_result "$(grep -m1 " $site\( \|:\|\$\)" /var/lib/homelab-playbook/watch.txt 2>/dev/null | cut -d' ' -f2-)"
fi
if [ -r /var/lib/homelab-playbook/audit.txt ]; then
  kv audit_at "$(stat -c %Y /var/lib/homelab-playbook/audit.txt)"
  kv audit_summary "$(tail -n 1 /var/lib/homelab-playbook/audit.txt)"
  kv audit_first_fail "$(grep -m1 '^  FAIL' /var/lib/homelab-playbook/audit.txt | sed 's/^  FAIL //')"
fi
if [ -r /var/lib/apt/periodic/upgrade-stamp ]; then kv updates_ok_at "$(stat -c %Y /var/lib/apt/periodic/upgrade-stamp)"; fi
exit 0
