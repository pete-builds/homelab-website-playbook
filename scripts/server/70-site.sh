#!/usr/bin/env bash
# Phase 5: put your site on the server and start it, reachable only from the
# server itself (127.0.0.1:SITE_PORT). The tunnel in Phase 6 publishes it.
#
# Run as your admin user ON THE SERVER (no sudo; you're in the docker group):
#   ./scripts/server/70-site.sh          (or, from the laptop: ./playbook server site)
# Safe to re-run: it deploys whatever origin/main is now, through the same
# script every later deploy uses (site-deploy.sh), so the first build is
# tagged, proven and rollback-able like every other.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SITE_NAME SITE_REPO SITE_PORT
validate_config || die "fix playbook.env first"
need_cmd git docker curl
[ "$(id -u)" -ne 0 ] || die "run this as your admin user, not with sudo: the site's files should belong to you"
docker info >/dev/null 2>&1 || die "can't talk to docker. Did you log out and back in after 50-docker.sh?"

dir="/srv/sites/$SITE_NAME"
if [ ! -d "$dir/.git" ]; then
  log "Cloning $SITE_REPO into $dir"
  git clone -q "$SITE_REPO" "$dir" || die "couldn't clone $SITE_REPO. A private repo needs a deploy key: docs/TROUBLESHOOTING.md#private-site-repo"
fi
ok "checkout at $(git -C "$dir" log -1 --format='%h %s')"

[ -f "$dir/docker-compose.yml" ] || die "$dir has no docker-compose.yml. Start from site-starter/ (scripts/local/new-site.sh)."
check_compose_ports "$dir/docker-compose.yml" \
  || die "every port in docker-compose.yml must be published on 127.0.0.1 (offending lines above). Docker bypasses the firewall for anything else."
grep -q "127.0.0.1:$SITE_PORT:80" "$dir/docker-compose.yml" \
  || die "docker-compose.yml doesn't publish 127.0.0.1:$SITE_PORT. SITE_PORT in playbook.env and the site's compose file disagree."

log "Building and starting (the build runs the site's own checks; a failing check fails the deploy)"
"$PLAYBOOK_ROOT/scripts/server/site-deploy.sh" deploy "$SITE_NAME" "$SITE_PORT"

ctrl=$(http_code "http://127.0.0.1:$SITE_PORT/__no_such_page_$$")
[ "$ctrl" = "404" ] || die "a page that doesn't exist answered $ctrl, not 404; checks against this server would prove nothing"
ok "home 200, missing page 404 (the check can tell them apart)"
