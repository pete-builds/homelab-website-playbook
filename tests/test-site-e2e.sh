#!/usr/bin/env bash
# End to end, minus the internet: new-site.sh renders a site, Docker builds it
# (its own checks run inside the build), the container runs on loopback, and
# verify-site.sh proves it: status, negative control, marker, build id, headers.
# Then the controls: a wrong build id and a missing marker must FAIL.
#   ./tests/test-site-e2e.sh            (needs Docker)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }

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
  (cd "$work/site" && docker compose down >/dev/null 2>&1)
done
exit "$rc"
