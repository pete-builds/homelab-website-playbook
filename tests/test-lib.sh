#!/usr/bin/env bash
# Unit tests for scripts/lib.sh helpers, including their failure paths.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib.sh
. "$root/scripts/lib.sh"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
n=0; bad=0
expect() { # expect <0|1> <label> <cmd...>
  local want="$1" label="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=0; else got=1; fi
  n=$((n + 1))
  if [ "$got" = "$want" ]; then echo "  OK   $label"; else echo "  FAIL $label (exit $got, wanted $want)"; bad=$((bad + 1)); fi
}
w() { printf '%s\n' "$2" > "$t/$1"; }

w good.yml "services:
  site:
    ports:
      - '127.0.0.1:8080:80'
    read_only: true"
w bare.yml "services:
  site:
    ports:
      - '8080:80'"
w mixed.yml "services:
  site:
    ports:
      - '127.0.0.1:8080:80'
      - '8443:443'"
w any.yml "services:
  site:
    ports:
      - \"0.0.0.0:8080:80\""
w none.yml "services:
  site:
    image: x"
expect 0 "compose gate: loopback-only passes" check_compose_ports "$t/good.yml"
expect 1 "compose gate: bare port fails" check_compose_ports "$t/bare.yml"
expect 1 "compose gate: one loopback + one public fails" check_compose_ports "$t/mixed.yml"
expect 1 "compose gate: 0.0.0.0 fails" check_compose_ports "$t/any.yml"
expect 1 "compose gate: no ports section fails" check_compose_ports "$t/none.yml"
w flow.yml "services:
  site:
    ports: ['8080:80']"
w flowlocal.yml "services:
  site:
    ports: [\"127.0.0.1:8080:80\"]"
expect 0 "compose gate: the real site-starter compose passes" check_compose_ports "$root/site-starter/docker-compose.yml"
expect 1 "compose gate: flow-style ports (publishes on 0.0.0.0) fails" check_compose_ports "$t/flow.yml"
expect 1 "compose gate: flow-style, even loopback, fails (one '- ' line per port)" check_compose_ports "$t/flowlocal.yml"
expect 0 "cidr: inside" ip_in_cidr 192.168.1.23 192.168.1.0/24
expect 1 "cidr: outside" ip_in_cidr 10.0.0.5 192.168.1.0/24
expect 1 "cidr: ipv6 vs ipv4 net" ip_in_cidr fe80::1 192.168.1.0/24
expect 1 "cidr: garbage" ip_in_cidr notanip 192.168.1.0/24

printf 'x={{A}} y={{B}}\n' > "$t/tpl"
A='a&b|c/d\e' B=ok expect 0 "render: special characters" render_template "$t/tpl" "$t/out"
grep -qxF 'x=a&b|c/d\e y=ok' "$t/out" && echo "  OK   render: value survives intact" || { echo "  FAIL render output: $(cat "$t/out")"; bad=$((bad + 1)); }
expect 1 "render: missing variable dies" bash -c ". '$root/scripts/lib.sh'; unset B; A=1 render_template '$t/tpl' '$t/out2'"

# validate_config: each bad value fails, the example values pass.
vc() { ( set +u; unset SITE_NAME DOMAIN SITE_PORT SSH_PORT SITE_MARKER ADMIN_USER REBOOT_TIME AUTO_DEPLOY LAN_CIDR SITE_REPO CF_ACCOUNT_ID
         eval "$1"; validate_config ) ; }
expect 0 "config: the example file's values pass" vc 'SITE_NAME=mysite DOMAIN=example.com SITE_PORT=8080 SSH_PORT=22 SITE_MARKER="Hello from mysite" ADMIN_USER=admin REBOOT_TIME=04:30 SITE_REPO=https://github.com/friend/mysite.git'
expect 0 "config: empty values are left to require_vars" vc 'true'
expect 1 "config: SITE_NAME with a space" vc 'SITE_NAME="My Site"'
expect 1 "config: DOMAIN with https://" vc 'DOMAIN=https://example.com'
expect 1 "config: DOMAIN without a dot" vc 'DOMAIN=localhost'
expect 1 "config: DOMAIN with a double dot" vc 'DOMAIN=example..com'
expect 1 "config: SITE_PORT not a number" vc 'SITE_PORT=80a'
expect 1 "config: SITE_PORT out of range" vc 'SITE_PORT=70000'
expect 1 "config: SITE_PORT equal to SSH_PORT" vc 'SITE_PORT=2222 SSH_PORT=2222'
expect 1 "config: SITE_MARKER with an apostrophe (HTML-escaped live)" vc "SITE_MARKER=\"Pete's site\""
expect 1 "config: ADMIN_USER root" vc 'ADMIN_USER=root'
expect 1 "config: REBOOT_TIME 25:00" vc 'REBOOT_TIME=25:00'
expect 1 "config: AUTO_DEPLOY maybe" vc 'AUTO_DEPLOY=maybe'
expect 1 "config: LAN_CIDR garbage" vc 'LAN_CIDR=192.168.1/24x'
expect 0 "config: LAN_CIDR a real network" vc 'LAN_CIDR=192.168.1.0/24'
expect 1 "config: SITE_REPO still the example" vc 'SITE_REPO=https://github.com/you/mysite.git'
expect 1 "config: CF_ACCOUNT_ID too short" vc 'CF_ACCOUNT_ID=abc123'
expect 0 "config: CF_ACCOUNT_ID 32 hex" vc 'CF_ACCOUNT_ID=0123456789abcdef0123456789abcdef'

# ssh_session_peers: SSH_CLIENT wins when it's there (the no-sudo case). The
# sudo case (SSH_CLIENT wiped, ss asked instead) runs for real in
# tests/linux/smoke-scripts.sh, with a real sshd and a real session.
peers=$(SSH_CLIENT="192.168.1.23 50000 22" ssh_session_peers)
[ "$peers" = "192.168.1.23" ] && { echo "  OK   peers: SSH_CLIENT is used when present"; n=$((n + 1)); } || { echo "  FAIL peers: got '$peers'"; bad=$((bad + 1)); n=$((n + 1)); }

# run_quiet: one line on success; the tail and the log path on failure.
out=$(XDG_STATE_HOME="$t/state" run_quiet "quiet ok" sh -c 'echo noise; echo more noise' 2>&1)
case "$out" in *noise*) echo "  FAIL run_quiet leaked output on success: $out"; bad=$((bad + 1)) ;; *OK*) echo "  OK   run_quiet: success is one line" ;; esac; n=$((n + 1))
out=$(XDG_STATE_HOME="$t/state" run_quiet "quiet fail" sh -c 'echo the-real-error; exit 7' 2>&1); rc=$?
case "$out" in *the-real-error*"full log:"*) [ "$rc" = 7 ] && echo "  OK   run_quiet: failure shows the tail, the log, and keeps exit 7" || { echo "  FAIL run_quiet exit $rc"; bad=$((bad + 1)); } ;;
  *) echo "  FAIL run_quiet failure output: $out"; bad=$((bad + 1)) ;; esac; n=$((n + 1))

echo "lib: $n checks, $bad failed"
[ "$bad" -eq 0 ]
