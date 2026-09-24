#!/usr/bin/env bash
# Check your laptop has everything the playbook needs. Read-only.
#   ./scripts/local/preflight.sh
set -uo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

rc=0
for c in git ssh curl python3 node npm; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else fail "$c is missing"; rc=1; fi
done
if command -v node >/dev/null 2>&1; then
  major=$(node -p 'process.versions.node.split(".")[0]')
  if [ "$major" -ge 22 ]; then ok "node $major (Astro needs 22+)"; else fail "node $major is too old; Astro needs 22.12+"; rc=1; fi
fi
if command -v gh >/dev/null 2>&1; then ok "gh (optional, makes creating the site repo one command)"; else warn "gh not installed (optional)"; fi

here="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "${PLAYBOOK_ENV:-$here/playbook.env}" ]; then
  ok "playbook.env present"
  load_config
  if [ -n "${SERVER_HOST:-}" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SERVER_HOST" true 2>/dev/null; then ok "ssh $SERVER_HOST works with your key"
    else warn "ssh $SERVER_HOST doesn't work yet (fine before Phase 1)"; fi
  fi
else
  warn "no playbook.env yet: cp playbook.env.example playbook.env"
fi

tok="$HOME/.config/homelab-playbook/cloudflare.token"
if [ -f "$tok" ]; then
  m=$(stat -f '%Lp' "$tok" 2>/dev/null || stat -c '%a' "$tok")
  if [ "$m" = "600" ]; then ok "Cloudflare token file is 600"; else fail "$tok is mode $m; chmod 600 it"; rc=1; fi
else
  warn "no Cloudflare API token yet (Phase 3)"
fi
exit "$rc"
