#!/usr/bin/env bash
# Phase 2d: kernel network hardening via sysctl.
#
# Run as root ON THE SERVER:  sudo ./scripts/server/40-kernel.sh
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
dest=/etc/sysctl.d/99-homelab-playbook.conf
cp "$PLAYBOOK_ROOT/templates/sysctl/99-homelab-playbook.conf" "$dest"
chmod 644 "$dest"
# sysctl exits non-zero if ANY key is unknown to this kernel. Don't die on that:
# the per-key check below says exactly which ones didn't apply.
sysctl --system >/dev/null 2>&1 || warn "sysctl rejected some settings; details below"

bad=0
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  key=$(printf '%s' "$line" | cut -d= -f1 | tr -d ' ')
  want=$(printf '%s' "$line" | cut -d= -f2 | tr -d ' ')
  have=$(sysctl -n "$key" 2>/dev/null || echo missing)
  if [ "$have" = "$want" ]; then ok "$key = $have"; else warn "$key is $have, wanted $want (kernel may not support it)"; bad=1; fi
done < "$dest"
[ "$bad" -eq 0 ] && ok "all kernel settings applied"
exit 0
