#!/usr/bin/env python3
"""Claude Code status line for this repo: where you are in the playbook, and
what this session has used.

    playbook 6/8 live FAIL > ./playbook why | ctx 23% | $0.41

Reads the snapshot `./playbook status` leaves behind (no network, no ssh: a
status line runs constantly and must be instant). Claude Code passes session
details as JSON on stdin; context and cost come from there.
"""
import json
import os
import sys
import time


def main():
    try:
        session = json.load(sys.stdin)
    except ValueError:
        session = {}
    parts = []
    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                         "homelab-playbook", "status.json")
    try:
        with open(state) as fh:
            snap = json.load(fh)
        age = time.time() - snap.get("at", 0)
        stale = " (old)" if age > 6 * 3600 else ""
        cur = snap.get("current")
        if cur:
            parts.append(f"playbook {cur['phase']}/8 {cur['name']} {cur['state']}{stale} > {snap.get('next', '')}")
        else:
            parts.append(f"playbook: all phases done{stale}")
    except (OSError, ValueError, KeyError, TypeError):
        parts.append("playbook: run ./playbook status")
    ctx = (session.get("context_window") or {}).get("used_percentage")
    if isinstance(ctx, (int, float)):
        parts.append(f"ctx {int(ctx)}%")
    cost = (session.get("cost") or {}).get("total_cost_usd")
    if isinstance(cost, (int, float)):
        parts.append(f"${cost:.2f}")
    print(" | ".join(parts))


if __name__ == "__main__":
    main()
