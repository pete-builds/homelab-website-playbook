#!/usr/bin/env bash
# Ship your site. Run on your LAPTOP from this repo:   ./scripts/local/deploy.sh
# (or ./playbook deploy)
#
#   1. refuses a dirty tree or another branch; if GitHub has commits you don't
#      (a Dependabot update you merged there, an edit in the browser), it pulls
#      them first, as long as that's a clean fast-forward
#   2. runs the site's own gates locally (npm ci, build, check); exit codes, not output
#   3. pushes, then on the server (scripts/server/site-deploy.sh, sent over ssh):
#      fast-forward, build an image for this commit, swap, prove /healthz and
#      the build id on 127.0.0.1
#   4. if the new container isn't healthy, the previous one is back by itself
#   5. proves the LIVE site serves THIS commit, through Cloudflare, with headers
#
# Nothing here uses rsync --delete. The server builds from git, so a bad local
# directory can never wipe the live site.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SERVER_HOST SITE_NAME SITE_DIR DOMAIN SITE_PORT
# LIVE_URL is for the test suite; your site is https://DOMAIN.
live="${LIVE_URL:-https://$DOMAIN}"
validate_config || die "fix playbook.env first"
need_cmd git ssh npm curl

site_dir="${SITE_DIR/#\~/$HOME}"
[ -d "$site_dir/.git" ] || die "SITE_DIR ($site_dir) is not a git repo"
cd "$site_dir"
log "Deploying $(pwd)"

# ── 1. Git preflight ─────────────────────────────────────────────────────────
[ -z "$(git status --porcelain)" ] || die "uncommitted changes. Commit or stash them; a deploy ships commits, not files."
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || die "you're on '$branch'. Deploy from main."
git fetch -q origin || die "can't reach origin. Check your network, or: git remote -v"
if ! git merge-base --is-ancestor origin/main HEAD; then
  if git merge-base --is-ancestor HEAD origin/main; then
    n=$(git rev-list --count HEAD..origin/main)
    git merge --ff-only -q origin/main || die "couldn't fast-forward to origin/main"
    ok "pulled $n commit(s) from GitHub first (e.g. a Dependabot update merged there)"
  else
    die "your main and GitHub's have both changed. Run: git pull --rebase   (then deploy again)"
  fi
fi
sha=$(git rev-parse --short=12 HEAD)
ok "clean, on main, up to date with origin ($sha)"

# ── 2. Local gates ───────────────────────────────────────────────────────────
log "Local gates: npm ci, build, check"
run_quiet "npm ci" npm ci --no-audit --no-fund
# A failed build leaves the OLD dist/ on disk. Trust the exit code, not the last line.
run_quiet "build" env PUBLIC_BUILD_ID="$sha" npm run build
# With PUBLIC_BUILD_ID set, check-dist also proves dist/ is THIS build, not a stale one.
PUBLIC_BUILD_ID="$sha" npm run --silent check || die "site checks failed (the lines above say which)"

# ── 3. Push + remote rebuild ─────────────────────────────────────────────────
git push -q origin main
ok "pushed $sha"

log "Deploying on $SERVER_HOST"
set +e
ssh_server bash -s -- deploy "$SITE_NAME" "$SITE_PORT" "$sha" < "$PLAYBOOK_ROOT/scripts/server/site-deploy.sh"
rc=$?
set -e
case "$rc" in
  0) ;;
  3) die "the new version was unhealthy, so the server put the previous one back (it's live and healthy). The lines above say why." ;;
  4) die "the new version AND the rollback failed: the site is DOWN. Run: ./playbook why" ;;
  *) die "the server refused or failed the deploy (exit $rc); the old version is still live. The lines above say why." ;;
esac

# ── 4. Prove it from the outside ─────────────────────────────────────────────
log "Verifying $live serves $sha"
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "$live" "build:$sha" \
  || die "the live site is not serving $sha. If it's an older commit, something is caching HTML; see docs/TROUBLESHOOTING.md#the-site-looks-old"
ok "live: $live is $sha"
