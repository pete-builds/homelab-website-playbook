#!/usr/bin/env python3
"""Every agent in .claude/skills/ follows the house format.

    python3 tests/validate-skills.py

  * frontmatter has `name` (matching its directory) and `description`
  * the description is under 400 characters (every description loads every session)
  * a `## Verification` block with Tier, Claim, Check, Control and On fail
  * every scripts/... path it mentions exists (docs that point at nothing rot silently)
  * every agent CLAUDE.md routes to has a skill, and vice versa
  * `model:`, when a skill sets one, is a model Claude Code accepts
  * every `./playbook <command> [<step>]` named in a skill, a doc or a script
    exists in ./playbook itself (control: a made-up one is caught)
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIELDS = ("Tier:", "Claim:", "Check:", "Control:", "On fail:")


FIXED_STEPS = {"domain": {"search", "check", "register", "status"}, "tunnel": {"create", "status"}}
DOC_FILES = ["CLAUDE.md", "README.md", "PLAYBOOK.md", "docs/TROUBLESHOOTING.md", "themes/README.md",
             "scripts/local/diagnose.py", "scripts/local/status.py", "scripts/local/new-site.sh",
             "scripts/local/cf-tunnel.py", "scripts/server/10-harden-ssh.sh", "scripts/server/90-watch.sh",
             "scripts/server/audit.sh", "scripts/server/00-bootstrap.sh", "templates/watch/homelab-watch",
             "templates/updates/homelab-refresh-containers", "site-starter/README.md"]


def playbook_commands():
    """(top-level commands, server steps, site steps) as ./playbook defines them."""
    text = open(os.path.join(ROOT, "playbook")).read()

    def labels(body, indent):
        out = set()
        for m in re.findall(rf"^{indent}([a-z|-]+(?:\|[a-z-]+)*)\)", body, re.M):
            out.update(x for x in m.split("|") if x)
        return out

    top = labels(text[text.rindex('case "$cmd" in'):], "  ")
    server = labels(text[text.index("server_cmd() {"):text.index("site_cmd() {")], "    ")
    site = labels(text[text.index("site_cmd() {"):text.rindex('case "$cmd" in')], "    ")
    return top, server, site


def bad_mentions(text, cmds):
    top, server, site = cmds
    steps = dict(FIXED_STEPS, server=server, site=site)
    bad = []
    for cmd, step in re.findall(r"\./playbook(?:[ \t]+([a-z][a-z-]*))?(?:[ \t]+([a-z][a-z-]*))?", text):
        if not cmd:
            continue
        if cmd not in top:
            bad.append(f"./playbook {cmd}")
        elif cmd in steps and step and step not in steps[cmd]:
            bad.append(f"./playbook {cmd} {step}")
    return bad


def main():
    errors = []
    skills = sorted(glob.glob(os.path.join(ROOT, ".claude", "skills", "*", "SKILL.md")))
    if not skills:
        errors.append("no skills found")
    names = set()
    for path in skills:
        rel = os.path.relpath(path, ROOT)
        text = open(path).read()
        m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
        if not m:
            errors.append(f"{rel}: no frontmatter")
            continue
        fm = dict(re.findall(r"^(\w+):\s*(.+)$", m.group(1), re.M))
        d = os.path.basename(os.path.dirname(path))
        names.add(d)
        if fm.get("name") != d:
            errors.append(f"{rel}: name '{fm.get('name')}' != directory '{d}'")
        desc = fm.get("description", "")
        if not desc:
            errors.append(f"{rel}: no description")
        elif len(desc) > 400:
            errors.append(f"{rel}: description is {len(desc)} chars (max 400)")
        if fm.get("model") and fm["model"] not in ("haiku", "sonnet", "opus", "inherit"):
            errors.append(f"{rel}: model '{fm['model']}' isn't haiku, sonnet, opus or inherit")
        ver = text.split("## Verification", 1)
        if len(ver) < 2:
            errors.append(f"{rel}: no '## Verification' block")
        else:
            for f in FIELDS:
                if f not in ver[1]:
                    errors.append(f"{rel}: Verification block lacks '{f}'")
        for ref in set(re.findall(r"(?<![\w/])((?:scripts|tests|templates|themes)/[\w./-]+\.(?:sh|py|mjs|css|conf|yml|md))", text)):
            if "<" in ref:
                continue
            if not os.path.exists(os.path.join(ROOT, ref)):
                errors.append(f"{rel}: references missing file {ref}")

    claude = open(os.path.join(ROOT, "CLAUDE.md")).read()
    routed = set(re.findall(r"^\| \*\*(\w+)\*\* \|", claude, re.M))
    for n in names - routed:
        errors.append(f"CLAUDE.md routing table has no row for skill '{n}'")
    for n in routed - names:
        errors.append(f"CLAUDE.md routes to '{n}', which has no skill")

    cmds = playbook_commands()
    checked = 0
    for rel in [os.path.relpath(p, ROOT) for p in skills] + DOC_FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            errors.append(f"{rel}: listed for the ./playbook mention check but missing")
            continue
        checked += 1
        for b in sorted(set(bad_mentions(open(path).read(), cmds))):
            errors.append(f"{rel}: mentions `{b}`, which ./playbook doesn't have")
    # Control: a made-up command and a made-up step must both be caught.
    if bad_mentions("run ./playbook launch, then ./playbook server teleport", cmds) != \
            ["./playbook launch", "./playbook server teleport"]:
        errors.append("control: the ./playbook mention check doesn't catch made-up commands")

    for e in errors:
        print(f"  FAIL {e}")
    if not errors:
        print(f"  OK   {len(skills)} skills valid, routing table matches, "
              f"every ./playbook mention in {checked} files exists (control caught a made-up one)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
