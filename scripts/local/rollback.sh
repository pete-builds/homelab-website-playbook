#!/usr/bin/env bash
# Put the previous deploy back, from your LAPTOP:   ./scripts/local/rollback.sh
# (or ./playbook rollback)
#
# The server remembers every commit it replaced. This starts the most recent
# one's image again (no rebuild), proves it on the server, then proves it live.
# Auto-deploy, if you turned it on, pauses until your next deploy, so it can't
# put the version you just rolled away from straight back.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SERVER_HOST SITE_NAME SITE_PORT DOMAIN
# LIVE_URL is for the test suite; your site is https://DOMAIN.
live="${LIVE_URL:-https://$DOMAIN}"

confirm "Roll $DOMAIN back to its previous deploy?" || die "cancelled"

out=$(ssh_server bash -s -- rollback "$SITE_NAME" "$SITE_PORT" < "$PLAYBOOK_ROOT/scripts/server/site-deploy.sh") \
  || { printf '%s\n' "$out"; die "rollback failed; the lines above say why"; }
printf '%s\n' "$out"
target=$(printf '%s\n' "$out" | sed -n 's/^OK \([0-9a-f]*\) is live.*/\1/p' | tail -n 1)
[ -n "$target" ] || die "the server didn't say which version is live"
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "$live" "build:$target" || die "live site is not serving $target yet"
ok "live: $live is $target"
