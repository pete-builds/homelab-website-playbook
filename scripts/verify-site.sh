#!/usr/bin/env bash
# verify-site.sh <url> [marker]  prove a site is really up, not just "200".
#
# A bare 200 proves little. A Cloudflare error page, a catch-all route, or the
# WRONG site can all answer 200. So this checks:
#   1. the page answers 200, as text/html (a server that sends HTML as a
#      download still answers 200, and curl doesn't care; browsers do)
#   2. a path that cannot exist does NOT answer 2xx (the negative control: if
#      the server answers everything, check 1 proved nothing)
#   3. the page contains a marker string that only YOUR page has
#   4. the four security headers nginx sets are present
# and, for an https:// URL, warns (without failing) when plain http:// isn't
# sent to https.
#
# Exit 0 pass, 1 fail, 2 usage, 3 INDETERMINATE: Cloudflare answered with a
# bot-check page instead of the site, so this run can say nothing either way.
# (Automated checks from data-center IPs, like GitHub's runners, get those.)
# Runs on macOS and Linux (bash 3.2+).
set -uo pipefail

URL="${1:-}"; MARKER="${2:-}"
[ -n "$URL" ] || { echo "usage: verify-site.sh <url> [marker]" >&2; exit 2; }
URL="${URL%/}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rc=0
pass() { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; rc=1; }
note() { printf '  WARN %s\n' "$*"; }

echo "verifying $URL"

# GET, not HEAD: some servers answer the two differently, and visitors GET.
code=$(curl -s -D "$tmp/h" -o "$tmp/body" -w '%{http_code}' --max-time 20 "$URL/")

# A challenge page is neither up nor down. Say so, and stop. The header is
# Cloudflare's documented signal. Body text alone is not: Cloudflare injects
# /cdn-cgi/challenge-platform/ scripts into perfectly normal pages, so only a
# non-200 "Just a moment..." page counts.
is_challenge=0
grep -i '^cf-mitigated: *challenge' "$tmp/h" >/dev/null 2>&1 && is_challenge=1
case "$code" in 403|429|503)
  grep -E '<title>Just a moment\.\.\.</title>' "$tmp/body" >/dev/null 2>&1 && is_challenge=1 ;;
esac
if [ "$is_challenge" -eq 1 ]; then
  echo "INDETERMINATE $URL: a Cloudflare challenge answered instead of the site (HTTP $code)."
  echo "  Checks from servers and CI are often challenged. From a normal browser, is the site there?"
  exit 3
fi

if [ "$code" = "200" ]; then pass "home page 200 ($(wc -c < "$tmp/body" | tr -d ' ') bytes)"
elif [ "$code" = "000" ]; then bad "no answer at all (DNS, TLS or connection failure)"; echo "FAIL $URL"; exit 1
else bad "home page answered $code"; fi

ctype=$(grep -i '^content-type:' "$tmp/h" | tail -n 1 | tr -d '\r' | cut -d' ' -f2-)
case "$ctype" in
  text/html*) pass "served as $ctype" ;;
  *) bad "served as '${ctype:-no content-type}', not text/html: browsers will download it instead of showing it (a types { } block in nginx replaces its whole MIME map)" ;;
esac

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

case "$URL" in
  https://*)
    loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "http://${URL#https://}/")
    case "$loc" in
      30[1278]\ https://*) pass "http:// redirects to https://" ;;
      *) note "http:// doesn't redirect to https:// (got '$loc'). Cloudflare dashboard > SSL/TLS > Edge Certificates > Always Use HTTPS" ;;
    esac ;;
esac

[ "$rc" -eq 0 ] && echo "PASS $URL" || echo "FAIL $URL"
exit "$rc"
