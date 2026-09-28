#!/usr/bin/env bash
# homelab-watch's state machine, driven through every transition with stubs:
# a fake site (python http.server) on the site port, a fake connector /ready
# endpoint, a stub docker, a stub verify-site, a notify stub that records
# every message, and a heartbeat receiver that counts pings.
#
#   blip (1 failure)         no message
#   second failure           ONE "DOWN" message, after a restart attempt
#   still down               no further messages
#   recovers                 ONE "back up" message
#   --boot                   always reports
#   all ok                   heartbeat pinged; any failure: not pinged
#
# Run inside the Linux container by smoke-scripts.sh (it also runs on any
# Linux box with python3 and curl).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
w="$(mktemp -d)"
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$w"; }
trap cleanup EXIT
pass=0; failn=0
t_ok()  { echo "  OK   watch: $*"; pass=$((pass + 1)); }
t_bad() { echo "  FAIL watch: $*"; failn=$((failn + 1)); }

site_port=18455; metrics_port=18456; hb_port=18457
export HLP_ETC="$w/etc" HLP_VAR="$w/var" HLP_LIB="$w/lib" HLP_NOTIFY="$w/notify" HLP_SETTLE=1
mkdir -p "$HLP_ETC/sites" "$HLP_LIB/scripts" "$w/bin" "$w/site" "$w/ready" "$w/hb"
printf "SITE_NAME='wsite'\nSITE_PORT='%s'\nDOMAIN='example.org'\nSITE_MARKER='Hello'\nTUNNEL_METRICS_PORT='%s'\n" "$site_port" "$metrics_port" > "$HLP_ETC/sites/wsite.conf"
printf 'HEARTBEAT_URL=http://127.0.0.1:%s/ping\n' "$hb_port" > "$HLP_ETC/notify.env"
printf '#!/bin/sh\necho "$*" >> %s/messages\n' "$w" > "$HLP_NOTIFY"
# verify-site: pass when the fake site is up, fail like the real one when not.
cat > "$HLP_LIB/scripts/verify-site.sh" <<EOF
#!/bin/sh
curl -sf -o /dev/null http://127.0.0.1:$site_port/ && { echo "PASS"; exit 0; }
echo "  FAIL home page answered 502"; exit 1
EOF
# docker: the connector is "running"; a restart is recorded, and does nothing.
cat > "$w/bin/docker" <<EOF
#!/bin/sh
case "\$1" in
  inspect) echo true ;;
  restart) echo "restart \$2" >> $w/restarts ;;
esac
EOF
chmod +x "$HLP_NOTIFY" "$HLP_LIB/scripts/verify-site.sh" "$w/bin/docker"
export PATH="$w/bin:$PATH"
touch "$w/site/healthz" "$w/site/index.html" "$w/ready/ready" "$w/hb/ping"

serve() { python3 -m http.server "$1" --bind 127.0.0.1 --directory "$2" >/dev/null 2>&1 & echo $!; }
wait_port() { i=0; until curl -s -o /dev/null "http://127.0.0.1:$1/"; do i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.1; done; }
cat > "$w/hb.py" <<'PY'
import sys, http.server
port, hits = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open(hits, "a").write("hit\n"); self.send_response(200); self.end_headers()
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
python3 "$w/hb.py" "$hb_port" "$w/hits" >/dev/null 2>&1 & pids="$pids $!"
ready_pid=$(serve "$metrics_port" "$w/ready"); pids="$pids $ready_pid"
wait_port "$metrics_port" || t_bad "ready endpoint didn't start"
# /ready must answer 200: python serves the file named "ready".
msgs() { cat "$w/messages" 2>/dev/null | wc -l | tr -d ' '; }
hits() { cat "$w/hits" 2>/dev/null | wc -l | tr -d ' '; }
watch() { "$root/templates/watch/homelab-watch" "$@" > "$w/last" 2>&1; }

# Site down from the start (nothing on site_port).
watch
[ "$(msgs)" = 0 ] && t_ok "one failure is a blip: no message" || t_bad "messaged on the first failure: $(cat "$w/messages")"
grep -q ' FAIL wsite: origin' "$HLP_VAR/watch.txt" && t_ok "watch.txt records the failure" || t_bad "watch.txt: $(cat "$HLP_VAR/watch.txt")"
[ "$(stat -c %a "$HLP_VAR/watch.txt")" = 644 ] && t_ok "watch.txt readable without sudo" || t_bad "watch.txt mode"
[ "$(hits)" = 0 ] && t_ok "no heartbeat while failing" || t_bad "heartbeat pinged while failing"

watch
[ "$(msgs)" = 1 ] && grep -q 'wsite is DOWN' "$w/messages" && t_ok "second failure: one DOWN message" || t_bad "after 2 failures: $(cat "$w/messages" 2>/dev/null)"
grep -q 'restart wsite' "$w/restarts" 2>/dev/null && t_ok "tried restarting the site container first" || t_bad "no restart attempt"
grep -q "didn't help" "$w/messages" && t_ok "says the restart didn't help" || t_bad "DOWN message doesn't say the restart failed"

watch
[ "$(msgs)" = 1 ] && t_ok "still down: no repeat message" || t_bad "repeated the DOWN message"

site_pid=$(serve "$site_port" "$w/site"); pids="$pids $site_pid"
wait_port "$site_port" || t_bad "fake site didn't start"
watch
[ "$(msgs)" = 2 ] && tail -n 1 "$w/messages" | grep -q 'wsite is back up' && t_ok "recovery: one 'back up' message" || t_bad "after recovery: $(cat "$w/messages")"
grep -q ' ok wsite' "$HLP_VAR/watch.txt" && t_ok "watch.txt says ok" || t_bad "watch.txt: $(cat "$HLP_VAR/watch.txt")"
[ "$(hits)" = 1 ] && t_ok "heartbeat pinged when everything passed" || t_bad "heartbeat hits: $(hits)"

watch
[ "$(msgs)" = 2 ] && t_ok "healthy: silence" || t_bad "messaged while healthy"

watch --boot
tail -n 1 "$w/messages" | grep -q 'back up after a reboot' && t_ok "--boot always reports" || t_bad "--boot: $(tail -n 1 "$w/messages")"

echo "== watch: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
