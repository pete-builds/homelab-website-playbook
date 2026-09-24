#!/usr/bin/env bash
# Ship your site. Run on your LAPTOP from this repo:   ./scripts/local/deploy.sh
#
#   1. refuses a dirty tree, and a branch that's behind or diverged from origin
#   2. runs the site's own gates locally (npm ci, build, check); exit codes, not output
#   3. pushes, then on the server: fast-forward, rebuild the container with the
#      commit id baked in, wait for /healthz
#   4. if the new container isn't healthy, rolls back to the previous commit by itself
#   5. proves the LIVE site serves THIS commit, through Cloudflare, with headers
#
# Nothing here uses rsync --delete. The server builds from git, so a bad local
# directory can never wipe the live site.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SERVER_HOST SITE_NAME SITE_DIR DOMAIN SITE_PORT
need_cmd git ssh npm curl

site_dir="${SITE_DIR/#\~/$HOME}"
[ -d "$site_dir/.git" ] || die "SITE_DIR ($site_dir) is not a git repo"
cd "$site_dir"
log "Deploying $(pwd)"

# ── 1. Git preflight ─────────────────────────────────────────────────────────
[ -z "$(git status --porcelain)" ] || die "uncommitted changes. Commit or stash them; a deploy ships commits, not files."
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || die "you're on '$branch'. Deploy from main."
git fetch -q origin
if ! git merge-base --is-ancestor origin/main HEAD; then
  die "origin/main has commits you don't. Run: git pull --ff-only   (then deploy again)"
fi
sha=$(git rev-parse --short=12 HEAD)
ok "clean, on main, up to date with origin ($sha)"

# ── 2. Local gates ───────────────────────────────────────────────────────────
log "Local gates: npm ci, build, check"
npm ci --no-audit --no-fund >/dev/null || die "npm ci failed"
# A failed build leaves the OLD dist/ on disk. Trust the exit code, not the last line.
PUBLIC_BUILD_ID="$sha" npm run build >/dev/null || die "build failed"
npm run check || die "site checks failed"
ok "build and checks pass"

# ── 3. Push + remote rebuild ─────────────────────────────────────────────────
git push -q origin main
ok "pushed $sha"

log "Rebuilding on $SERVER_HOST"
# Paths are absolute: a ~ inside an ssh command string expands on the wrong machine.
# shellcheck disable=SC2087
ssh "$SERVER_HOST" bash -s -- "$SITE_NAME" "$SITE_PORT" "$sha" <<'REMOTE'
set -euo pipefail
site=$1; port=$2; want=$3
cd "/srv/sites/$site"
git checkout -q main 2>/dev/null || true
prev=$(git rev-parse --short=12 HEAD)
git fetch -q origin
git merge --ff-only -q origin/main || { echo "server checkout has diverged from origin; fix it by hand" >&2; exit 1; }
now=$(git rev-parse --short=12 HEAD)
[ "$now" = "$want" ] || { echo "server is at $now after pulling, expected $want" >&2; exit 1; }
[ "$prev" = "$now" ] || echo "$prev" >> .deploy-history

healthy() {
  i=0
  while [ "$i" -lt 30 ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/healthz")" = "200" ] && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

if BUILD_ID="$now" docker compose up -d --build && healthy; then
  echo "server: $now is up and healthy"
  exit 0
fi
echo "server: $now FAILED; rolling back to $prev" >&2
git checkout -q --detach "$prev"
BUILD_ID="$prev" docker compose up -d --build && healthy && echo "server: rolled back to $prev (healthy)" >&2
exit 3
REMOTE
ok "server rebuilt and healthy"

# ── 4. Prove it from the outside ─────────────────────────────────────────────
log "Verifying https://$DOMAIN serves $sha"
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://$DOMAIN" "build:$sha" \
  || die "the live site is not serving $sha. If it's an older commit, something is caching HTML; see docs/TROUBLESHOOTING.md"
ok "live: https://$DOMAIN is $sha"
