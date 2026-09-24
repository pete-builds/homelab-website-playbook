#!/usr/bin/env bash
# Phase 6 (server half): run the Cloudflare tunnel connector and prove the site
# is live on the internet.
#
# Create the tunnel first, from your laptop:  scripts/local/cf-tunnel.py create
# (./playbook server tunnel does both halves.)
#
# Run as your admin user ON THE SERVER. The token is read from, in order:
#   1. $CLOUDFLARE_TUNNEL_TOKEN
#   2. stdin, when piped:   ssh server './scripts/server/80-tunnel.sh' < token-file
#   3. a hidden prompt
# It never appears in arguments, shell history, the process list, or the
# container's environment: it lives in a mode-600 file the container reads.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SITE_NAME DOMAIN SITE_PORT SITE_MARKER
validate_config || die "fix playbook.env first"
need_cmd docker curl
[ "$(id -u)" -ne 0 ] || die "run this as your admin user, not with sudo: the token file must belong to you"
TUNNEL_METRICS_PORT="${TUNNEL_METRICS_PORT:-20241}"
ADMIN_UID=$(id -u); ADMIN_GID=$(id -g)
export TUNNEL_METRICS_PORT ADMIN_UID ADMIN_GID

dir="/srv/cloudflared/$SITE_NAME"
[ "$(http_code "http://127.0.0.1:$SITE_PORT/healthz")" = "200" ] \
  || die "the site isn't answering on 127.0.0.1:$SITE_PORT. Run 70-site.sh first: a tunnel to a dead origin comes up 'healthy' and serves 502."

mkdir -p "$dir"
# The version: CLOUDFLARED_VERSION if you set one, else whatever a previous
# install (or update-tunnel.sh) pinned, else the version this playbook tested.
if [ -z "${CLOUDFLARED_VERSION:-}" ] && [ -f "$dir/docker-compose.yml" ]; then
  CLOUDFLARED_VERSION=$(sed -n 's/.*cloudflare\/cloudflared:\([^ "]*\).*/\1/p' "$dir/docker-compose.yml" | head -n 1)
fi
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.9.1}"
export CLOUDFLARED_VERSION
render_template "$PLAYBOOK_ROOT/templates/cloudflared/docker-compose.yml" "$dir/docker-compose.yml"

# An install from before the token moved out of the environment: move it,
# without it ever passing through a variable that could be printed.
if [ -s "$dir/.env" ] && [ ! -s "$dir/token" ]; then
  ( umask 077; sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' "$dir/.env" | tr -d '\r\n' > "$dir/token" )
  [ -s "$dir/token" ] && rm -f "$dir/.env" && ok "moved the token from .env into $dir/token (600)"
fi

token="${CLOUDFLARE_TUNNEL_TOKEN:-}"
if [ -z "$token" ] && [ ! -t 0 ]; then
  IFS= read -r token || true
fi
if [ -z "$token" ] && [ -s "$dir/token" ]; then
  ok "token already installed in $dir/token; verifying the existing install"
elif [ -z "$token" ]; then
  printf 'Paste the tunnel token (input hidden): '
  stty -echo 2>/dev/null || true
  IFS= read -r token || token=''
  stty echo 2>/dev/null || true
  printf '\n'
fi
if [ -n "$token" ]; then
  case "$token" in ey*) ;; *) die "that doesn't look like a tunnel token (they start with 'ey')" ;; esac
  # No trailing newline: the file is the token, byte for byte.
  ( umask 077; printf '%s' "$token" > "$dir/token" )
  chmod 600 "$dir/token"
  ok "wrote $dir/token (600)"
fi
unset token
[ -s "$dir/token" ] || die "no token given"

run_quiet "start the connector (cloudflared $CLOUDFLARED_VERSION)" docker compose -f "$dir/docker-compose.yml" up -d

log "Waiting for the connector to connect to Cloudflare"
i=0
until [ "$(http_code "http://127.0.0.1:$TUNNEL_METRICS_PORT/ready")" = "200" ]; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    docker logs --tail 20 "cloudflared-$SITE_NAME" 2>&1 | sed 's/^/      /' >&2
    die "the connector isn't ready after 60s. Wrong or revoked token? (./playbook why reads the lines above)"
  fi
  sleep 2
done
ok "connector ready (127.0.0.1:$TUNNEL_METRICS_PORT/ready)"

log "Verifying from the internet (through Cloudflare, the way visitors arrive)"
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://$DOMAIN" "$SITE_MARKER" || {
  cat >&2 <<EOF

Reading the failure:
  404, no security headers  the tunnel has no ingress rule for $DOMAIN (its
                            catch-all answered). Re-run: cf-tunnel.py create
  502                       the tunnel is up but the site isn't answering
  Error 1033 (HTTP 530)     no connector is running for this tunnel
  000 / no answer           no DNS record. A tunnel "hostname route" is NOT a DNS
                            record: the zone needs proxied CNAMEs to
                            <tunnel-id>.cfargotunnel.com. cf-tunnel.py creates them.
  Error 1014                the domain and the tunnel are in DIFFERENT Cloudflare accounts
New DNS can take a few minutes. Re-run this script; the token is already installed.
EOF
  exit 1
}
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://www.$DOMAIN" "$SITE_MARKER" >/dev/null || warn "www.$DOMAIN is not serving yet"
ok "$DOMAIN is live"
