#!/usr/bin/env bash
# Phase 8: keep watch. The server tells you when something breaks, and
# (only if you turn it on) deploys what you push.
#
#   every 10 min   homelab-watch: origin, tunnel, the public site, disk. Tells you
#                  when something breaks (twice in a row) and when it's back.
#                  Restarts a stuck container once. Pings HEARTBEAT_URL when all is
#                  well, so a push monitor can tell you when the server goes silent.
#   daily 06:15    homelab-audit: the full security audit; tells you about NEW failures
#   every 5 min    homelab-autodeploy, only with AUTO_DEPLOY=yes: deploys origin/main
#                  when it moves, with the same build, proof and rollback as a laptop deploy
#   after a boot   the watch runs once and always reports: "back up, healthy" or what isn't
#
# Run as root ON THE SERVER once the tunnel is up:   sudo ./scripts/server/90-watch.sh
# (from the laptop: ./playbook server watch). Safe to re-run; re-run it after
# updating the playbook, so the installed copies match.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars SITE_NAME SITE_PORT DOMAIN SITE_MARKER ADMIN_USER
validate_config || die "fix playbook.env first"
AUTO_DEPLOY="${AUTO_DEPLOY:-no}"
TUNNEL_METRICS_PORT="${TUNNEL_METRICS_PORT:-20241}"
id "$ADMIN_USER" >/dev/null 2>&1 || die "$ADMIN_USER doesn't exist. Run 00-bootstrap.sh first."
need_cmd docker curl runuser

ETC=/etc/homelab-playbook; VAR=/var/lib/homelab-playbook; LIB=/usr/local/lib/homelab-playbook
T="$PLAYBOOK_ROOT/templates/watch"

log "Installing the checks (root-owned copies, so nothing root runs is user-writable)"
install -d -m 755 "$LIB/scripts/server" "$VAR"
install -d -m 700 "$ETC" "$ETC/sites"
install -m 644 "$PLAYBOOK_ROOT/scripts/lib.sh" "$LIB/scripts/lib.sh"
install -m 755 "$PLAYBOOK_ROOT/scripts/verify-site.sh" "$LIB/scripts/verify-site.sh"
install -m 755 "$PLAYBOOK_ROOT/scripts/server/audit.sh" "$LIB/scripts/server/audit.sh"
install -m 755 "$PLAYBOOK_ROOT/scripts/server/site-deploy.sh" "$LIB/scripts/server/site-deploy.sh"
for f in homelab-watch homelab-audit homelab-autodeploy; do install -m 755 "$T/$f" "/usr/local/sbin/$f"; done
ok "installed homelab-watch, homelab-audit, homelab-autodeploy"

# Values are validated above (validate_config), so none holds a quote.
( umask 077
  printf "SITE_NAME='%s'\nSITE_PORT='%s'\nDOMAIN='%s'\nSITE_MARKER='%s'\nADMIN_USER='%s'\nAUTO_DEPLOY='%s'\nTUNNEL_METRICS_PORT='%s'\n" \
    "$SITE_NAME" "$SITE_PORT" "$DOMAIN" "$SITE_MARKER" "$ADMIN_USER" "$AUTO_DEPLOY" "$TUNNEL_METRICS_PORT" \
    > "$ETC/sites/$SITE_NAME.conf" )
ok "watching $SITE_NAME ($DOMAIN)"

# The heartbeat URL is a secret like the notify URL: whoever has it can fake
# "all is well". Hidden prompt, then into the same mode-600 file.
nenv="$ETC/notify.env"
if [ -z "${HEARTBEAT_URL:-}" ] && ! grep -q '^HEARTBEAT_URL=' "$nenv" 2>/dev/null && [ -t 0 ]; then
  cat <<'EOF'

Optional, recommended: a heartbeat. If the server dies or the power goes out, it
can't tell you. A free push monitor can: create a check at https://healthchecks.io
(period 10 minutes, grace 30 minutes) and paste its ping URL. The server pings it
whenever everything passes; when the pings stop, healthchecks.io emails you.
EOF
  printf 'Heartbeat ping URL (Enter to skip, input hidden): '
  stty -echo 2>/dev/null || true
  IFS= read -r HEARTBEAT_URL || HEARTBEAT_URL=''
  stty echo 2>/dev/null || true
  printf '\n'
fi
if [ -n "${HEARTBEAT_URL:-}" ]; then
  case "$HEARTBEAT_URL" in https://*) ;; *) die "the heartbeat URL should start with https://" ;; esac
  rest=$(grep -v '^HEARTBEAT_URL=' "$nenv" 2>/dev/null || true)
  write_secret_file "$nenv" "$(printf '%s\nHEARTBEAT_URL=%s' "$rest" "$HEARTBEAT_URL" | sed '/^$/d')"
  ok "heartbeat URL saved in $nenv (600)"
elif grep -q '^HEARTBEAT_URL=' "$nenv" 2>/dev/null; then
  ok "heartbeat already configured"
else
  warn "no heartbeat: if the whole server goes down, nothing will tell you"
fi

log "Timers"
alert="OnFailure=homelab-alert@%n.service"
[ -f /etc/systemd/system/homelab-alert@.service ] || alert=""
cat > /etc/systemd/system/homelab-watch.service <<EOF
[Unit]
Description=Is the site up? (homelab-website-playbook)
After=docker.service network-online.target
Wants=network-online.target
$alert

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-watch
EOF
cat > /etc/systemd/system/homelab-watch.timer <<'EOF'
[Unit]
Description=Check the site every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/homelab-audit.service <<EOF
[Unit]
Description=Daily security audit (homelab-website-playbook)
$alert

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-audit
EOF
cat > /etc/systemd/system/homelab-audit.timer <<'EOF'
[Unit]
Description=Daily security audit

[Timer]
OnCalendar=*-*-* 06:15:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/homelab-autodeploy.service <<EOF
[Unit]
Description=Deploy origin/main when it moves (AUTO_DEPLOY=yes)
After=docker.service network-online.target
Wants=network-online.target
$alert

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-autodeploy
EOF
cat > /etc/systemd/system/homelab-autodeploy.timer <<'EOF'
[Unit]
Description=Check for new commits every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now homelab-watch.timer homelab-audit.timer >/dev/null
if [ "$AUTO_DEPLOY" = yes ]; then
  systemctl enable --now homelab-autodeploy.timer >/dev/null
  ok "auto-deploy ON: a push to main goes live within ~5 minutes (checks, proof and rollback included)"
else
  systemctl disable --now homelab-autodeploy.timer >/dev/null 2>&1 || true
  ok "auto-deploy off (set AUTO_DEPLOY=yes in playbook.env and re-run to turn it on)"
fi

log "First run, now"
/usr/local/sbin/homelab-watch | sed 's/^/  watch: /'
/usr/local/sbin/homelab-audit | sed 's/^/  audit: /'
systemctl list-timers --all --no-pager 'homelab-*' | sed -n '1,12p' || true

if grep -q ' FAIL ' "$VAR/watch.txt"; then
  die "the watch is installed, but its first check FAILED (above). Fix that, then: sudo /usr/local/sbin/homelab-watch"
fi
ok "watching. Results: $VAR/watch.txt and $VAR/audit.txt (./playbook status shows both)"
