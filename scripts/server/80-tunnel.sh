#!/usr/bin/env bash
# Phase 6 (server half): run the Cloudflare tunnel connector and prove the site
# is live on the internet.
#
# Create the tunnel first, from your laptop:  scripts/local/cf-tunnel.py create
# It saves the tunnel token to a mode-600 file and prints how to get it here.
#
# Run as your admin user ON THE SERVER. The token is read from, in order:
#   1. $CLOUDFLARE_TUNNEL_TOKEN
#   2. stdin, when piped:   ssh server './scripts/server/80-tunnel.sh' < token-file
#   3. a hidden prompt
# It never appears in arguments, shell history or the process list.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

load_config
require_vars SITE_NAME DOMAIN SITE_PORT SITE_MARKER
need_cmd docker curl
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.9.1}"
export CLOUDFLARED_VERSION

dir="/srv/cloudflared/$SITE_NAME"
[ "$(http_code "http://127.0.0.1:$SITE_PORT/healthz")" = "200" ] \
  || die "the site isn't answering on 127.0.0.1:$SITE_PORT. Run 70-site.sh first: a tunnel to a dead origin comes up 'healthy' and serves 502."

mkdir -p "$dir"
render_template "$PLAYBOOK_ROOT/templates/cloudflared/docker-compose.yml" "$dir/docker-compose.yml"

token="${CLOUDFLARE_TUNNEL_TOKEN:-}"
if [ -z "$token" ] && [ ! -t 0 ]; then
  IFS= read -r token || true
fi
if [ -z "$token" ] && [ -s "$dir/.env" ]; then
  ok "token already installed in $dir/.env; verifying the existing install"
elif [ -z "$token" ]; then
  printf 'Paste the tunnel token (input hidden): '
  stty -echo 2>/dev/null || true
  IFS= read -r token || token=''
  stty echo 2>/dev/null || true
  printf '\n'
fi
if [ -n "$token" ]; then
  case "$token" in ey*) ;; *) die "that doesn't look like a tunnel token (they start with 'ey')" ;; esac
  write_secret_file "$dir/.env" "CLOUDFLARE_TUNNEL_TOKEN=$token"
  ok "wrote $dir/.env (600)"
fi
[ -s "$dir/.env" ] || die "no token given"

( cd "$dir" && docker compose up -d )

log "Waiting for the connector to register with Cloudflare"
i=0
# grep -c, not grep -q: under pipefail, -q exits on the first match, docker
# logs dies of SIGPIPE, and the pipeline "fails" because the line WAS found.
until docker logs "cloudflared-$SITE_NAME" 2>&1 | grep -c "Registered tunnel connection" >/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    docker logs --tail 20 "cloudflared-$SITE_NAME" >&2
    die "no 'Registered tunnel connection' after 60s. Wrong or revoked token?"
  fi
  sleep 2
done
ok "connector registered"

log "Verifying from the internet (through Cloudflare, the way visitors arrive)"
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://$DOMAIN" "$SITE_MARKER" || {
  cat >&2 <<EOF

Reading the failure:
  503 from Cloudflare  the tunnel has no ingress rule for $DOMAIN
  Error 1016           the connector is down (check: docker logs cloudflared-$SITE_NAME)
  000 / no answer      no DNS record. A tunnel "hostname route" is NOT a DNS
                       record: the zone needs proxied CNAMEs to
                       <tunnel-id>.cfargotunnel.com. cf-tunnel.py creates them.
  Error 1014           the domain and the tunnel are in DIFFERENT Cloudflare accounts
New DNS can take a few minutes. Re-run this script; the token is already installed.
EOF
  exit 1
}
"$PLAYBOOK_ROOT/scripts/verify-site.sh" "https://www.$DOMAIN" "$SITE_MARKER" || warn "www.$DOMAIN is not serving yet"
ok "$DOMAIN is live"
