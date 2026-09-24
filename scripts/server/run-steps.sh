#!/usr/bin/env bash
# Run server phase scripts in order, stopping at the first one that fails.
# `./playbook server <step>` uses it so one sudo (one password) covers them all.
#   sudo ./scripts/server/run-steps.sh 20-firewall.sh 30-fail2ban.sh
set -euo pipefail
cd "$(dirname "$0")"
for s in "$@"; do
  case "$s" in *[!a-z0-9.-]*|'') echo "not a step: $s" >&2; exit 2 ;; esac
  [ -x "./$s" ] || { echo "no step ./scripts/server/$s" >&2; exit 2; }
  printf '\n=== %s\n' "$s"
  "./$s"
done
