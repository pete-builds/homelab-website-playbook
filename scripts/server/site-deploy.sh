#!/usr/bin/env bash
# The one place that changes which version of a site is live, ON THE SERVER.
#
#   site-deploy.sh deploy   <site> <port> [<sha>]  fast-forward to origin/main (which must be
#                                                  <sha> when given), build, swap, prove it,
#                                                  or put the previous version back by itself
#   site-deploy.sh rollback <site> <port>          put the previous deploy back
#   site-deploy.sh sync     <site> <port>          deploy only if origin/main moved (the
#                                                  auto-deploy timer; see 90-watch.sh)
#
# The laptop pipes THIS file over ssh (scripts/local/deploy.sh), so the laptop's
# version is always the one that runs. The auto-deploy timer runs the copy that
# 90-watch.sh installs. Run it as the admin user (docker group), never root.
#
# Every build is tagged <site>-site:<commit> (docker-compose.yml names its image
# by BUILD_ID). A rollback starts the previous commit's image as it is, with no
# rebuild, so it still works when npm or Docker Hub is the thing that broke.
#
# Build output goes to a log file. What prints is one line per step, and the
# tail of the log when something fails.
#
# Exit: 0 live and proven (or nothing to do)
#       1 refused or failed before anything changed: the old version is still live
#       3 the new version was unhealthy and the previous one is back, healthy
#       4 the new version failed AND the rollback failed: the site is DOWN
set -euo pipefail

# (Not `sed "$0"`: piped over ssh, $0 is just "bash".)
usage() { echo "usage: site-deploy.sh deploy|rollback|sync <site> <port> [<sha>]" >&2; exit 2; }
cmd=${1:-}; site=${2:-}; port=${3:-}; want=${4:-}
case "$cmd" in deploy|rollback|sync) ;; *) usage ;; esac
case "$site" in ''|*[!a-z0-9-]*) echo "site name must be lowercase letters, digits and dashes" >&2; exit 2 ;; esac
case "$port" in ''|*[!0-9]*) echo "port must be a number" >&2; exit 2 ;; esac
[ "$(id -u)" -ne 0 ] || { echo "run this as the admin user, not root (it would leave root-owned files in the checkout)" >&2; exit 2; }

dir="${SITES_ROOT:-/srv/sites}/$site"
state="${SITES_ROOT:-/srv/sites}/.state/$site"
img="$site-site"
[ -d "$dir/.git" ] || { echo "$dir is not a git checkout. Run 70-site.sh first." >&2; exit 1; }
mkdir -p "$state/logs"
log="$state/logs/$(date +%Y%m%d-%H%M%S)-$cmd.log"
: > "$log"
# Keep the last 20 logs.
# shellcheck disable=SC2012
ls -1t "$state/logs" | sed -n '21,$p' | while IFS= read -r old; do rm -f "$state/logs/$old"; done

# One deploy at a time: the timer and a laptop deploy must never interleave.
# (flock is util-linux: every supported server has it. The test suite also runs
# this on macOS, which doesn't.)
if command -v flock >/dev/null 2>&1; then
  exec 9>"$state/lock"
  flock -n 9 || { echo "another deploy of $site is running; try again in a minute" >&2; exit 1; }
fi

say()  { printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$log"; }
show_log() { echo "---- last lines of $log" >&2; tail -n 25 "$log" >&2; echo "----" >&2; }
notify() { [ -x /usr/local/sbin/homelab-notify ] && /usr/local/sbin/homelab-notify "$*" >/dev/null 2>&1 || true; }
short() { git -C "$dir" rev-parse --short=12 "$1"; }
has_image() { docker image inspect "$img:$1" >/dev/null 2>&1; }

cd "$dir"
compose() { docker compose "$@" >> "$log" 2>&1; }

# healthy <build>: /healthz answers 200 AND the home page carries exactly this
# build id. The second half proves the NEW container is the one answering, not
# a leftover. 30 tries, a second apart.
healthy() {
  local b="$1" i=0 page="$state/home.html"
  while [ "$i" -lt 30 ]; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/healthz")" = "200" ] \
      && curl -s --max-time 5 -o "$page" "http://127.0.0.1:$port/" \
      && grep -F "content=\"build:$b\"" "$page" >/dev/null; then
      return 0
    fi
    i=$((i + 1)); sleep 1
  done
  return 1
}

# start <build>: run the image for that commit (building it if it isn't there),
# then prove it.
start() {
  local b="$1"
  if has_image "$b"; then
    BUILD_ID="$b" compose up -d --no-build --force-recreate
  else
    git checkout -q --detach "$b"
    BUILD_ID="$b" compose up -d --build --force-recreate
  fi && healthy "$b"
}

record() { printf '%s\n' "$1" >> "$state/history"; }

# Keep the images of the last 5 commits in the history, plus whatever runs now.
prune_images() {
  local keep
  # (No history yet on a first deploy: tail fails, and under pipefail that
  # would fail the whole deploy AFTER it went live.)
  keep=" $({ tail -n 5 "$state/history" 2>/dev/null || true; } | tr '\n' ' ') $1 dev "
  docker image ls "$img" --format '{{.Tag}}' 2>/dev/null | while IFS= read -r t; do
    case "$keep" in *" $t "*) ;; *) docker image rm "$img:$t" >/dev/null 2>&1 || true ;; esac
  done
}

deploy() {
  local running target
  running=$(short HEAD)
  git fetch -q origin 2>>"$log" || { show_log; say "FAIL can't fetch from origin (network, or a private repo without a deploy key)"; return 1; }
  target=$(short origin/main)
  if [ -n "$want" ] && [ "$target" != "$want" ]; then
    say "FAIL origin/main is $target, but the laptop pushed $want. Push again, then deploy."
    return 1
  fi
  if [ "$cmd" = sync ]; then
    if [ -f "$state/paused" ]; then say "auto-deploy is paused ($(cat "$state/paused")). A deploy from the laptop resumes it."; return 0; fi
    if [ "$(cat "$state/failed" 2>/dev/null)" = "$target" ]; then say "origin/main ($target) already failed once; waiting for a new commit"; return 0; fi
    if [ "$target" = "$running" ] && healthy "$running"; then return 0; fi
  fi
  say "deploying $target (live now: $running)"

  # Build first. Until the image exists, nothing about the live site changes.
  git checkout -q main 2>>"$log" || git checkout -q -b main origin/main 2>>"$log"
  if ! git merge --ff-only -q origin/main 2>>"$log"; then
    git checkout -q --detach "$running"
    say "FAIL the server's copy of main has commits GitHub doesn't. Someone edited on the server; resolve it by hand (never force)."
    return 1
  fi
  if ! BUILD_ID="$target" compose build; then
    git checkout -q --detach "$running"
    printf '%s\n' "$target" > "$state/failed"
    show_log
    say "FAIL the build of $target failed (its own checks run inside it). $running is still live, untouched."
    return 1
  fi
  say "built $img:$target"

  if BUILD_ID="$target" compose up -d --no-build --force-recreate && healthy "$target"; then
    [ "$running" = "$target" ] || record "$running"
    rm -f "$state/failed" "$state/paused"
    prune_images "$target"
    say "OK $target is live on 127.0.0.1:$port and proven (healthz 200, build:$target on the home page)"
    return 0
  fi

  show_log
  say "FAIL $target started but isn't healthy. Rolling back to $running."
  printf '%s\n' "$target" > "$state/failed"
  git checkout -q --detach "$running"
  if start "$running"; then
    say "rolled back: $running is live again and healthy"
    return 3
  fi
  show_log
  say "FAIL the rollback to $running is ALSO unhealthy. THE SITE IS DOWN."
  notify "SITE DOWN: $site. Deploy of $target failed and the rollback to $running failed too. Logs: $log"
  return 4
}

rollback() {
  local current prev
  [ -s "$state/history" ] || { say "FAIL no previous deploy recorded; nothing to roll back to"; return 1; }
  current=$(short HEAD)
  prev=$(tail -n 1 "$state/history")
  say "rolling back $current -> $prev"
  if start "$prev"; then
    git checkout -q --detach "$prev"
    sed '$d' "$state/history" > "$state/history.tmp" && mv "$state/history.tmp" "$state/history"
    # Auto-deploy would put main straight back. Hold it until a laptop deploy.
    printf 'rolled back to %s on %s\n' "$prev" "$(date '+%F %T')" > "$state/paused"
    prune_images "$prev"
    say "OK $prev is live on 127.0.0.1:$port and proven. Auto-deploy (if on) is paused until your next deploy."
    return 0
  fi
  show_log
  say "FAIL $prev isn't healthy; putting $current back"
  git checkout -q --detach "$current"
  if start "$current"; then say "still on $current (healthy)"; return 1; fi
  notify "SITE DOWN: $site. Rollback to $prev failed and $current won't come back."
  say "FAIL $current won't come back either. THE SITE IS DOWN."
  return 4
}

case "$cmd" in
  deploy|sync) deploy ;;
  rollback) rollback ;;
esac
