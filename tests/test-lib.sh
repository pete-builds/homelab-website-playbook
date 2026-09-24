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
expect 0 "compose gate: the real site-starter compose passes" check_compose_ports "$root/site-starter/docker-compose.yml"
expect 0 "cidr: inside" ip_in_cidr 192.168.1.23 192.168.1.0/24
expect 1 "cidr: outside" ip_in_cidr 10.0.0.5 192.168.1.0/24
expect 1 "cidr: ipv6 vs ipv4 net" ip_in_cidr fe80::1 192.168.1.0/24
expect 1 "cidr: garbage" ip_in_cidr notanip 192.168.1.0/24

printf 'x={{A}} y={{B}}\n' > "$t/tpl"
A='a&b|c/d\e' B=ok expect 0 "render: special characters" render_template "$t/tpl" "$t/out"
grep -qxF 'x=a&b|c/d\e y=ok' "$t/out" && echo "  OK   render: value survives intact" || { echo "  FAIL render output: $(cat "$t/out")"; bad=$((bad + 1)); }
expect 1 "render: missing variable dies" bash -c ". '$root/scripts/lib.sh'; unset B; A=1 render_template '$t/tpl' '$t/out2'"

echo "lib: $n checks, $bad failed"
[ "$bad" -eq 0 ]
