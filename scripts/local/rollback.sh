#!/usr/bin/env bash
# Put the previous deploy back, from your LAPTOP:   ./scripts/local/rollback.sh
#
# The server remembers every commit it replaced in /srv/sites/<site>/.deploy-history.
# This checks out the most recent one (detached), rebuilds, and verifies the
# live site. Your next ./scripts/local/deploy.sh returns the server to main.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SERVER_HOST SITE_NAME SITE_PORT DOMAIN

confirm "Roll $DOMAIN back to its previous deploy?" || die "cancelled"

# shellcheck disable=SC2087
target=$(ssh_server bash -s -- "$SITE_NAME" "$SITE_PORT" <<'REMOTE'
set -euo pipefail
site=$1; port=$2
cd "/srv/sites/$site"
[ -s .deploy-history ] || { echo "no previous deploy recorded" >&2; exit 1; }
prev=$(tail -n 1 .deploy-history)
git checkout -q --detach "$prev"
BUILD_ID="$prev" docker compose up -d --build >&2
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/healthz")" = "200" ]; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "rolled-back build is not healthy" >&2; exit 1; }
  sleep 1
done
# Drop it from history so a second rollback goes one further back.
sed '$d' .deploy-history > .deploy-history.tmp && mv .deploy-history.tmp .deploy-history
echo "$prev"
REMOTE
)
ok "server is back on $target"
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://$DOMAIN" "build:$target" || die "live site is not serving $target yet"
ok "live: https://$DOMAIN is $target"
