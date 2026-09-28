#!/usr/bin/env python3
"""The permission rules in .claude/settings.json do what they claim.

    python3 tests/check-settings.py

Claude Code's matcher isn't something CI can run, so this implements the
DOCUMENTED semantics (code.claude.com/docs/en/permissions):
  * `*` matches any text, spaces included, anywhere in a Bash rule
  * `:*` is a prefix wildcard ONLY at the end of a rule; anywhere else the
    colon is a literal character
  * deny and ask rules apply to each subcommand of a compound command
  * absolute paths in Read rules are written `//path` (`/path` is relative
    to the project)
and asserts real commands land where they should: secret reads denied, the
purchase path asks, the read-only playbook commands run without a prompt.

The control: the rules this repo shipped before, `Bash(cat:*.token*)` and
friends, must FAIL the same checks. They matched nothing, and a check that
can't tell them apart from working rules proves nothing.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DENY = [
    "cat ~/.config/homelab-playbook/cloudflare.token",
    "head -c 40 ~/.config/homelab-playbook/tunnel-mysite.token",
    "/bin/cat ~/.config/homelab-playbook/cloudflare.token",
    "cd /tmp && cat ~/.config/homelab-playbook/cloudflare.token",
    "ssh homelab cat /srv/cloudflared/mysite/token",
    "ssh -t homelab 'sudo cat /etc/homelab-playbook/notify.env'",
    "ssh homelab 'sudo grep URL /etc/homelab-playbook/notify.env'",
    "tail /srv/cloudflared/mysite/.env",
    "base64 < ~/.config/homelab-playbook/cloudflare.token",
    "sed -n p /srv/cloudflared/mysite/token",
]
NOT_DENIED = [
    "stat -f %Lp ~/.config/homelab-playbook/cloudflare.token",
    "stat -c %a /srv/cloudflared/mysite/token",
    "ls -la ~/.config/homelab-playbook/",
    "./playbook status",
    "./playbook server tunnel",
    "cat playbook.env.example",
    "cat PLAYBOOK.md",
]
ASK = [
    "./scripts/local/cf-domain.py register mapleandpine.com",
    "python3 scripts/local/cf-domain.py register mapleandpine.com --years 2",
    "./playbook domain register mapleandpine.com",
    "script -q /dev/null ./scripts/local/cf-domain.py register x.com",
]
ALLOW = ["./playbook", "./playbook status", "./playbook status --json", "./playbook why",
         "./playbook guide 6", "./playbook doctor", "./scripts/verify-site.sh https://example.com"]
MCP_ASK = ["mcp__cloudflare-api__execute", "mcp__plugin_cloudflare_cloudflare__execute"]


def bash_rules(rules):
    return [r[5:-1] for r in rules if r.startswith("Bash(") and r.endswith(")")]


def matches(pattern, command):
    if pattern.endswith(":*"):
        prefix = pattern[:-2]
        return command == prefix or command.startswith(prefix + " ")
    if "*" in pattern:
        return fnmatch.fnmatchcase(command, pattern)
    return command == pattern


def subcommands(command):
    return [c.strip() for c in re.split(r"&&|\|\||;|\|", command) if c.strip()]


def hit(rules, command, compound=True):
    parts = subcommands(command) if compound else [command]
    return any(matches(p, part) for p in bash_rules(rules) for part in parts + [command])


def check(perms, label):
    errors = []
    deny, ask, allow = perms.get("deny", []), perms.get("ask", []), perms.get("allow", [])
    for c in DENY:
        if not hit(deny, c):
            errors.append(f"{label}: NOT denied: {c}")
    for c in NOT_DENIED:
        if hit(deny, c):
            errors.append(f"{label}: denied but harmless: {c}")
    for c in ASK:
        if not hit(ask, c):
            errors.append(f"{label}: doesn't ask: {c}")
    for c in ALLOW:
        if not hit(allow, c, compound=False) or hit(deny, c) or hit(ask, c):
            errors.append(f"{label}: not allowed without a prompt: {c}")
    for t in MCP_ASK:
        if t not in ask:
            errors.append(f"{label}: MCP tool {t} doesn't ask")
    for r in deny + ask + allow:
        if ":*" in r[:-3] or re.search(r":\*(?!\)$)", r):
            errors.append(f"{label}: ':*' is only a wildcard at the END of a rule: {r}")
        m = re.fullmatch(r"(Read|Edit|Write)\((/[^/].*)\)", r)
        if m:
            errors.append(f"{label}: {r} is relative to the project; an absolute path is //{m.group(2)[1:]}")
    return errors


def main():
    settings = json.load(open(os.path.join(ROOT, ".claude", "settings.json")))
    errors = check(settings["permissions"], "settings.json")
    for e in errors:
        print(f"  FAIL {e}")
    if not errors:
        print(f"  OK   settings.json: {len(DENY)} secret reads denied, {len(NOT_DENIED)} harmless commands not, "
              f"{len(ASK)} purchase paths ask, {len(ALLOW)} read-only commands allowed")

    # Control: the rules shipped in the first release must fail these checks.
    old = {"deny": ["Read(~/.config/homelab-playbook/**)", "Read(**/.env)", "Read(**/*.token)",
                    "Bash(cat:*homelab-playbook*)", "Bash(head:*homelab-playbook*)", "Bash(tail:*homelab-playbook*)",
                    "Bash(less:*homelab-playbook*)", "Bash(cat:*.env*)", "Bash(cat:*.token*)"],
           "ask": ["mcp__cloudflare-api__execute"]}
    old_errors = check(old, "old")
    if any("NOT denied: cat ~/.config/homelab-playbook/cloudflare.token" in e for e in old_errors) \
            and any("':*' is only a wildcard" in e for e in old_errors):
        print("  OK   control: the first release's `cat:*` rules fail this check (they matched nothing)")
    else:
        print("  FAIL control: the old, dead rules pass; this check can't tell working rules from dead ones")
        errors.append("control")

    statusline = settings.get("statusLine", {}).get("command", "")
    if statusline:
        script = statusline.split()[-1]
        if not os.path.exists(os.path.join(ROOT, script)):
            errors.append(f"statusLine runs {script}, which doesn't exist")
            print(f"  FAIL statusLine runs {script}, which doesn't exist")
        else:
            sample = json.dumps({"context_window": {"used_percentage": 12.5}, "cost": {"total_cost_usd": 0.42}})
            out = subprocess.run([sys.executable, os.path.join(ROOT, script)], input=sample, capture_output=True,
                                 text=True, timeout=10, cwd=ROOT, env=dict(os.environ, HOME="/nonexistent"))
            if out.returncode != 0 or "ctx 12%" not in out.stdout:
                errors.append("statusline")
                print(f"  FAIL statusLine output: {out.stdout!r} {out.stderr[-300:]!r}")
            else:
                print(f"  OK   statusLine: {out.stdout.strip()}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
