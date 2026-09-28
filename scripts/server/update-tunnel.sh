#!/usr/bin/env bash
# Move the tunnel connector (cloudflared) to a newer version, and put the old
# one back by itself if the new one doesn't connect or the site stops answering.
#
# Run as your admin user ON THE SERVER:
#   ./scripts/server/update-tunnel.sh            the latest release
#   ./scripts/server/update-tunnel.sh 2026.9.1   an exact version
# (from the laptop: ./playbook server tunnel-update)
#
# cloudflared is pinned on purpose: a new release can change behavior, and the
# tunnel is the only way in. The weekly refresh tells you when one is out; this
# is the one command that moves the pin, with a check that can fail after it.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SITE_NAME DOMAIN SITE_MARKER
need_cmd docker curl
TUNNEL_METRICS_PORT="${TUNNEL_METRICS_PORT:-20241}"
dir="/srv/cloudflared/$SITE_NAME"
compose="$dir/docker-compose.yml"
[ -f "$compose" ] || die "no tunnel installed at $dir. Run 80-tunnel.sh first."

want="${1:-}"
if [ -z "$want" ]; then
  want=$(curl -fsS --max-time 15 https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) || true
  [ -n "$want" ] || die "couldn't read the latest cloudflared release from GitHub; pass a version: update-tunnel.sh 2026.9.1"
fi
case "$want" in [0-9][0-9][0-9][0-9].[0-9]*) ;; *) die "'$want' doesn't look like a cloudflared version (e.g. 2026.9.1)" ;; esac
have=$(sed -n 's/.*cloudflare\/cloudflared:\([^ "]*\).*/\1/p' "$compose" | head -n 1)
if [ "$have" = "$want" ]; then ok "already on cloudflared $want"; exit 0; fi
log "cloudflared $have -> $want"

ready() {
  local i=0
  while [ "$i" -lt 30 ]; do
    [ "$(http_code "http://127.0.0.1:$TUNNEL_METRICS_PORT/ready")" = "200" ] && return 0
    i=$((i + 1)); sleep 2
  done
  return 1
}

cp "$compose" "$compose.bak"
sed "s|cloudflare/cloudflared:$have|cloudflare/cloudflared:$want|" "$compose.bak" > "$compose"
if run_quiet "pull cloudflared $want" docker compose -f "$compose" pull \
  && run_quiet "start cloudflared $want" docker compose -f "$compose" up -d \
  && ready \
  && "$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://$DOMAIN" "$SITE_MARKER" >/dev/null; then
  rm -f "$compose.bak"
  ok "cloudflared $want is connected and https://$DOMAIN verifies"
  exit 0
fi

warn "cloudflared $want didn't come up healthy; putting $have back"
mv "$compose.bak" "$compose"
docker compose -f "$compose" up -d >/dev/null 2>&1 || true
if ready && "$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://$DOMAIN" "$SITE_MARKER" >/dev/null; then
  die "stayed on cloudflared $have (healthy). $want didn't work here: docker logs cloudflared-$SITE_NAME"
fi
[ -x /usr/local/sbin/homelab-notify ] && /usr/local/sbin/homelab-notify "tunnel update to $want failed AND $have isn't healthy either: the site may be DOWN" || true
die "cloudflared $have isn't healthy after the rollback either. The site may be down: ./playbook why"
