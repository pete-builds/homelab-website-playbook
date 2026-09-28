#!/usr/bin/env bash
# End to end, minus the internet: new-site.sh renders a site, Docker builds it
# (its own checks run inside the build), the container runs on loopback, and
# verify-site.sh proves it: status, negative control, marker, build id, headers.
# Then the controls: a wrong build id and a missing marker must FAIL.
#   ./tests/test-site-e2e.sh            (needs Docker)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }

# CI runners have no git identity; new-site.sh commits, so give it one.
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.com GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.com
work="$(mktemp -d)"
port=18181
name="e2e$$"
cleanup() { (cd "$work/site" 2>/dev/null && docker compose down -v --rmi local >/dev/null 2>&1) || true; rm -rf "$work"; }
trap cleanup EXIT

cat > "$work/playbook.env" <<EOF
SITE_NAME=$name
DOMAIN=example.org
SITE_PORT=$port
SITE_MARKER="Hello from the e2e test"
SITE_TITLE="Pete's \"Quoted\" & <Tagged> Shop"
SITE_DESCRIPTION="Apostrophes aren't a problem; neither are {braces}."
SITE_DIR=$work/site
EOF
rc=0
for theme in midnight parchment moss velvet; do
  rm -rf "$work/site"
  PLAYBOOK_ENV="$work/playbook.env" "$root/scripts/local/new-site.sh" --theme "$theme" >/dev/null
  (cd "$work/site" && BUILD_ID="e2e-$theme" docker compose up -d --build --quiet-pull >/dev/null 2>&1) \
    || { echo "FAIL $theme: build or start failed"; rc=1; continue; }
  i=0; until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/healthz")" = "200" ]; do
    i=$((i + 1)); [ "$i" -lt 30 ] || break; sleep 1; done
  if "$root/scripts/verify-site.sh" "http://127.0.0.1:$port" "build:e2e-$theme" >/dev/null \
     && "$root/scripts/verify-site.sh" "http://127.0.0.1:$port" "Hello from the e2e test" >/dev/null; then
    echo "  OK   $theme: builds, serves, headers, build id, marker"
  else
    echo "  FAIL $theme"; "$root/scripts/verify-site.sh" "http://127.0.0.1:$port" "build:e2e-$theme" || true; rc=1
  fi
  if "$root/scripts/verify-site.sh" "http://127.0.0.1:$port" "build:some-other-commit" >/dev/null; then
    echo "  FAIL control: verify-site passed for the WRONG build id"; rc=1
  else echo "  OK   control: wrong build id is caught"; fi
  # The blog and feeds exist, and nginx's directory redirect stays RELATIVE:
  # an absolute one says http://, and would bounce an https visitor to plain http.
  b="http://127.0.0.1:$port"
  loc=$(curl -sI "$b/blog" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')
  if [ "$loc" = "/blog/" ]; then echo "  OK   $theme: /blog redirects to a relative /blog/"
  else echo "  FAIL $theme: /blog redirects to '$loc' (absolute redirects send https visitors to http)"; rc=1; fi
  for path in /blog/ /blog/your-first-post/ /rss.xml /robots.txt /sitemap-index.xml; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$b$path")
    [ "$code" = 200 ] || { echo "  FAIL $theme: $path answered $code"; rc=1; }
  done
  if curl -s "$b/rss.xml" | python3 -c 'import sys, xml.etree.ElementTree as E; r = E.fromstring(sys.stdin.read()); assert r.find("channel/item/title") is not None'; then
    echo "  OK   $theme: blog, post, rss.xml (well-formed, has the post), robots.txt, sitemap all 200"
  else echo "  FAIL $theme: rss.xml isn't well-formed or has no items"; rc=1; fi
  hdr=$(curl -sI "$b/" | tr -d '\r')
  printf '%s\n' "$hdr" | grep -qi '^strict-transport-security: max-age=' && echo "  OK   $theme: HSTS" || { echo "  FAIL $theme: no HSTS header"; rc=1; }
  # Caching: nothing outside /assets/ may be cached (its name never changes);
  # hashed files under /assets/ cache for a year.
  printf '%s\n' "$(curl -sI "$b/favicon.svg" | tr -d '\r')" | grep -qi '^cache-control: no-cache' \
    && echo "  OK   $theme: public files are no-cache" || { echo "  FAIL $theme: /favicon.svg is cacheable"; rc=1; }
  asset=$(curl -s "$b/" | grep -o '/assets/[^"]*\.css' | head -n 1)
  printf '%s\n' "$(curl -sI "$b$asset" | tr -d '\r')" | grep -qi '^cache-control: max-age=31536000' \
    && echo "  OK   $theme: hashed assets cache for a year ($asset)" || { echo "  FAIL $theme: $asset isn't cached for a year"; rc=1; }
  (cd "$work/site" && docker compose down >/dev/null 2>&1)
done
exit "$rc"
