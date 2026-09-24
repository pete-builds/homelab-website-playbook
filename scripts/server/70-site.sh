#!/usr/bin/env bash
# Phase 5: put your site on the server and start it, reachable only from the
# server itself (127.0.0.1:SITE_PORT). The tunnel in Phase 6 publishes it.
#
# Run as your admin user ON THE SERVER (no sudo; you're in the docker group):
#   ./scripts/server/70-site.sh
# Safe to re-run: it fast-forwards an existing checkout instead of re-cloning.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SITE_NAME SITE_REPO SITE_PORT
need_cmd git docker curl
docker info >/dev/null 2>&1 || die "can't talk to docker. Did you log out and back in after 50-docker.sh?"

dir="/srv/sites/$SITE_NAME"
if [ -d "$dir/.git" ]; then
  log "Updating $dir"
  git -C "$dir" fetch -q origin
  git -C "$dir" merge --ff-only -q "origin/$(git -C "$dir" rev-parse --abbrev-ref HEAD)" \
    || die "$dir has commits origin doesn't. Resolve by hand; never force it on a server."
else
  log "Cloning $SITE_REPO into $dir"
  git clone -q "$SITE_REPO" "$dir"
fi
ok "at $(git -C "$dir" log -1 --format='%h %s')"

[ -f "$dir/docker-compose.yml" ] || die "$dir has no docker-compose.yml. Start from site-starter/ (scripts/local/new-site.sh)."
grep -q "127.0.0.1:" "$dir/docker-compose.yml" \
  || die "docker-compose.yml must publish on 127.0.0.1 only. Docker bypasses the firewall for 0.0.0.0 ports."

log "Building and starting (the build runs the site's own checks; a failing check fails the deploy)"
( cd "$dir" && SITE_PORT="$SITE_PORT" docker compose up -d --build )

log "Waiting for http://127.0.0.1:$SITE_PORT/healthz"
i=0
until [ "$(http_code "http://127.0.0.1:$SITE_PORT/healthz")" = "200" ]; do
  i=$((i + 1)); [ "$i" -lt 30 ] || die "site never became healthy. Logs: cd $dir && docker compose logs --tail 50"
  sleep 1
done
ok "healthy on 127.0.0.1:$SITE_PORT"

code=$(http_code "http://127.0.0.1:$SITE_PORT/")
[ "$code" = "200" ] || die "home page answered $code"
ctrl=$(http_code "http://127.0.0.1:$SITE_PORT/__no_such_page_$$")
[ "$ctrl" = "404" ] || die "a page that doesn't exist answered $ctrl, not 404; checks against this server would prove nothing"
ok "home 200, missing page 404 (the check can tell them apart)"
