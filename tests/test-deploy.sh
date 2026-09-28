#!/usr/bin/env bash
# The deploy and rollback paths, for real: Docker builds, a local bare repo
# stands in for GitHub, and scripts/server/site-deploy.sh runs exactly as the
# laptop sends it. Then deploy.sh and rollback.sh themselves, with `ssh` swapped
# for a shim that runs the remote half locally.
#
# Every failure path gets a commit built to trigger it:
#   good -> good          history, build id, live proof
#   build fails           old version untouched, exit 1, remembered as failed
#   builds but unhealthy  automatic rollback, exit 3
#   sync                  skips a known-bad commit; pauses after a rollback
#   rollback              previous image, no rebuild; auto-deploy paused
#   wrong sha             refused before anything changes
#
#   ./tests/test-deploy.sh            (needs Docker)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

work="$(mktemp -d)"
port=18282
name="deploy$$"
export SITES_ROOT="$work/srv"
cleanup() {
  (cd "$SITES_ROOT/$name" 2>/dev/null && docker compose down -v >/dev/null 2>&1) || true
  docker image ls "$name-site" --format '{{.Tag}}' 2>/dev/null | while IFS= read -r t; do docker image rm -f "$name-site:$t" >/dev/null 2>&1 || true; done
  rm -rf "$work"
}
trap cleanup EXIT

pass=0; bad=0
t_ok()  { echo "  OK   $*"; pass=$((pass + 1)); }
t_bad() { echo "  FAIL $*"; bad=$((bad + 1)); }
live_build() { curl -s --max-time 5 "http://127.0.0.1:$port/" | sed -n 's/.*name="build" content="build:\([^"]*\)".*/\1/p' | head -n 1; }
deploy() { # deploy <cmd> [sha] -> sets rc and out
  set +e
  out=$(bash -s -- "$1" "$name" "$port" ${2:+"$2"} < "$root/scripts/server/site-deploy.sh" 2>&1)
  rc=$?
  set -e
}
expect_rc() { if [ "$rc" = "$1" ]; then t_ok "$2 (exit $rc)"; else t_bad "$2: exit $rc, wanted $1"; printf '%s\n' "$out" | tail -n 15; fi; }
expect_live() { local got; got=$(live_build); if [ "$got" = "$1" ]; then t_ok "$2: live is $got"; else t_bad "$2: live is '$got', wanted $1"; fi; }

cat > "$work/playbook.env" <<EOF
SITE_NAME=$name
DOMAIN=example.org
SITE_PORT=$port
SITE_MARKER="Hello from the deploy test"
SITE_DIR=$work/site
EOF
PLAYBOOK_ENV="$work/playbook.env" "$root/scripts/local/new-site.sh" --theme midnight >/dev/null
git init -q --bare -b main "$work/origin.git"
git -C "$work/site" remote add origin "$work/origin.git"
git -C "$work/site" push -q origin main
mkdir -p "$SITES_ROOT"
git clone -q "$work/origin.git" "$SITES_ROOT/$name"
commit() { # commit <message> : a new commit on the laptop copy, pushed; prints its sha
  git -C "$work/site" commit -qam "$1" && git -C "$work/site" push -q origin main
  git -C "$work/site" rev-parse --short=12 HEAD
}

echo "== first deploy"
sha1=$(git -C "$work/site" rev-parse --short=12 HEAD)
deploy deploy "$sha1"; expect_rc 0 "first deploy"
expect_live "$sha1" "first deploy"
docker image inspect "$name-site:$sha1" >/dev/null 2>&1 && t_ok "image tagged with the commit" || t_bad "no image $name-site:$sha1"

echo "== second deploy"
sed -i.bak 's/Two or three short paragraphs/Two short paragraphs/' "$work/site/src/pages/index.astro" && rm -f "$work/site/src/pages/index.astro.bak"
sha2=$(commit "second")
deploy deploy "$sha2"; expect_rc 0 "second deploy"
expect_live "$sha2" "second deploy"
[ "$(tail -n 1 "$SITES_ROOT/.state/$name/history")" = "$sha1" ] && t_ok "history remembers $sha1" || t_bad "history: $(cat "$SITES_ROOT/.state/$name/history")"

echo "== a commit whose build fails (an inline script: check-dist fails inside the Docker build)"
printf '<script is:inline>console.log(1)</script>\n' >> "$work/site/src/pages/index.astro"
sha3=$(commit "broken build")
deploy deploy "$sha3"; expect_rc 1 "build failure is refused"
expect_live "$sha2" "after the failed build, the old version"
printf '%s\n' "$out" | grep -q 'still live, untouched' && t_ok "says the old version is untouched" || t_bad "no 'untouched' line"
[ "$(git -C "$SITES_ROOT/$name" rev-parse --short=12 HEAD)" = "$sha2" ] && t_ok "server checkout is back on what's running" || t_bad "checkout left on the broken commit"

echo "== a commit that builds but isn't healthy (/healthz answers 500)"
sed -i.bak '$d' "$work/site/src/pages/index.astro" && rm -f "$work/site/src/pages/index.astro.bak"
sed -i.bak "s/return 200 'ok';/return 500 'broken';/" "$work/site/nginx.conf" && rm -f "$work/site/nginx.conf.bak"
sha4=$(commit "unhealthy")
deploy deploy "$sha4"; expect_rc 3 "unhealthy deploy rolls back by itself"
expect_live "$sha2" "after the automatic rollback"

echo "== sync (auto-deploy) never retries a commit that already failed"
deploy sync; expect_rc 0 "sync on a known-bad origin/main"
printf '%s\n' "$out" | grep -q 'already failed once' && t_ok "sync skipped $sha4" || t_bad "sync didn't recognise the failed commit: $out"
expect_live "$sha2" "after sync"

echo "== the deploy must match what the laptop pushed"
deploy deploy "000000000000"; expect_rc 1 "a sha that isn't origin/main is refused"
expect_live "$sha2" "after the refused deploy"

echo "== rollback: previous image, no rebuild"
deploy rollback; expect_rc 0 "rollback"
expect_live "$sha1" "after rollback"
printf '%s\n' "$out" | grep -q "^OK $sha1 is live" && t_ok "prints the OK line rollback.sh parses" || t_bad "no 'OK <sha> is live' line: $out"
rlog=$(ls -1t "$SITES_ROOT/.state/$name/logs/"*-rollback.log | head -n 1)
if grep -q 'npm run build' "$rlog"; then t_bad "rollback rebuilt the image"; else t_ok "rollback reused the image (no build in its log)"; fi
[ -f "$SITES_ROOT/.state/$name/paused" ] && t_ok "auto-deploy paused after a rollback" || t_bad "not paused after rollback"
# Fix the site on the laptop; sync must still hold (paused), a real deploy resumes.
sed -i.bak "s/return 500 'broken';/return 200 'ok';/" "$work/site/nginx.conf" && rm -f "$work/site/nginx.conf.bak"
sha5=$(commit "fixed")
deploy sync; expect_rc 0 "sync while paused"
expect_live "$sha1" "sync while paused leaves $sha5 waiting"

echo "== deploy.sh and rollback.sh themselves (ssh shimmed to run the remote half here)"
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Drop ssh's options and the host, run the remote command here.
while [ $# -gt 0 ]; do case "$1" in -p|-l|-o) shift 2 ;; -*) shift ;; *) shift; break ;; esac; done
exec "$@"
EOF
# The laptop's local gates need Node 22 for Astro; the Docker build runs the
# same gates, so here npm only has to succeed.
printf '#!/bin/sh\nexit 0\n' > "$work/bin/npm"
chmod +x "$work/bin/ssh" "$work/bin/npm"
cat >> "$work/playbook.env" <<EOF
SERVER_HOST=fake-server
ADMIN_USER=friend
LIVE_URL=http://127.0.0.1:$port
EOF
# GitHub moves ahead of the laptop (a Dependabot merge): deploy.sh must pull it first.
git clone -q "$work/origin.git" "$work/elsewhere"
printf 'merged on GitHub\n' > "$work/elsewhere/NOTE.md"
git -C "$work/elsewhere" add -A && git -C "$work/elsewhere" commit -qm "merged on GitHub" && git -C "$work/elsewhere" push -q origin main
sha6=$(git -C "$work/elsewhere" rev-parse --short=12 HEAD)
set +e
dout=$(PATH="$work/bin:$PATH" PLAYBOOK_ENV="$work/playbook.env" "$root/scripts/local/deploy.sh" 2>&1); drc=$?
set -e
[ "$drc" = 0 ] && t_ok "deploy.sh pulled GitHub's commit and shipped it" || { t_bad "deploy.sh exit $drc"; printf '%s\n' "$dout" | tail -n 20; }
printf '%s\n' "$dout" | grep -q 'pulled 1 commit' && t_ok "deploy.sh said it pulled first" || t_bad "no 'pulled' line"
expect_live "$sha6" "deploy.sh"
[ ! -f "$SITES_ROOT/.state/$name/paused" ] && t_ok "a laptop deploy resumes auto-deploy" || t_bad "still paused after a deploy"
# A dirty tree is refused.
printf 'x' >> "$work/site/src/site.json"
set +e; dout=$(PATH="$work/bin:$PATH" PLAYBOOK_ENV="$work/playbook.env" "$root/scripts/local/deploy.sh" 2>&1); drc=$?; set -e
[ "$drc" != 0 ] && printf '%s\n' "$dout" | grep -q 'uncommitted changes' && t_ok "deploy.sh refuses a dirty tree" || t_bad "dirty tree not refused ($drc)"
git -C "$work/site" checkout -q -- src/site.json
set +e; rout=$(PATH="$work/bin:$PATH" PLAYBOOK_ENV="$work/playbook.env" ASSUME_YES=1 "$root/scripts/local/rollback.sh" 2>&1); rrc=$?; set -e
[ "$rrc" = 0 ] && t_ok "rollback.sh" || { t_bad "rollback.sh exit $rrc"; printf '%s\n' "$rout" | tail -n 15; }
# sha5 never went live (sync was paused), so the deploy before sha6 was sha1.
expect_live "$sha1" "rollback.sh"

echo "deploy: $pass passed, $bad failed"
[ "$bad" -eq 0 ]
