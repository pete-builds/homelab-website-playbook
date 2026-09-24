#!/usr/bin/env bash
# verify-site.sh <url> [marker]  prove a site is really up, not just "200".
#
# A bare 200 proves little. A Cloudflare error page, a catch-all route, or the
# WRONG site can all answer 200. So this checks four things:
#   1. the page answers 200
#   2. a path that cannot exist does NOT answer 2xx (the negative control: if
#      the server answers everything, check 1 proved nothing)
#   3. the page contains a marker string that only YOUR page has
#   4. the four security headers nginx sets are present
#
# Exit 0 pass, 1 fail, 2 usage. Runs on macOS and Linux (bash 3.2+).
set -uo pipefail

URL="${1:-}"; MARKER="${2:-}"
[ -n "$URL" ] || { echo "usage: verify-site.sh <url> [marker]" >&2; exit 2; }
URL="${URL%/}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rc=0
pass() { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; rc=1; }

echo "verifying $URL"

# GET, not HEAD: some servers answer the two differently, and visitors GET.
code=$(curl -s -D "$tmp/h" -o "$tmp/body" -w '%{http_code}' --max-time 20 "$URL/")
if [ "$code" = "200" ]; then pass "home page 200 ($(wc -c < "$tmp/body" | tr -d ' ') bytes)"
elif [ "$code" = "000" ]; then bad "no answer at all (DNS, TLS or connection failure)"; exit 1
else bad "home page answered $code"; fi

ctrl=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$URL/__verify_control_$$_$RANDOM")
case "$ctrl" in
  2*) bad "a page that cannot exist answered $ctrl. The server answers everything, so check 1 proves nothing." ;;
  *)  pass "negative control: missing page answered $ctrl" ;;
esac

if [ -n "$MARKER" ]; then
  # grep the saved file, never `curl | grep -q` (under pipefail that can fail
  # BECAUSE the match was found: grep exits early and curl dies of SIGPIPE).
  if grep -F -- "$MARKER" "$tmp/body" >/dev/null; then pass "page contains \"$MARKER\""
  else bad "page does NOT contain \"$MARKER\" (wrong site, error page, or old build)"; fi
fi

for h in content-security-policy x-content-type-options referrer-policy permissions-policy; do
  if grep -i "^$h:" "$tmp/h" >/dev/null; then pass "header $h"
  else bad "header $h missing (an add_header inside a location block drops every inherited one)"; fi
done

if grep -i '^cf-cache-status:' "$tmp/h" >/dev/null; then
  pass "served through Cloudflare ($(grep -i '^cf-cache-status:' "$tmp/h" | tr -d '\r' | cut -d' ' -f2))"
fi

[ "$rc" -eq 0 ] && echo "PASS $URL" || echo "FAIL $URL"
exit "$rc"
