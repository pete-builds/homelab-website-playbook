#!/usr/bin/env python3
"""Every agent in .claude/skills/ follows the house format.

    python3 tests/validate-skills.py

  * frontmatter has `name` (matching its directory) and `description`
  * the description is under 400 characters (every description loads every session)
  * a `## Verification` block with Tier, Claim, Check, Control and On fail
  * every scripts/... path it mentions exists (docs that point at nothing rot silently)
  * every agent CLAUDE.md routes to has a skill, and vice versa
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIELDS = ("Tier:", "Claim:", "Check:", "Control:", "On fail:")


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

    for e in errors:
        print(f"  FAIL {e}")
    if not errors:
        print(f"  OK   {len(skills)} skills valid, routing table matches")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
