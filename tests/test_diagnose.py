#!/usr/bin/env python3
"""`./playbook why` (scripts/local/diagnose.py) knows what it claims to know.

    python3 tests/test_diagnose.py

  * every catalog entry's example line diagnoses as that entry, first
  * every entry points at a section that exists in docs/TROUBLESHOOTING.md
  * every entry names an agent that exists
  * a clean, successful run matches NOTHING (the control: a diagnoser that
    matches everything would pass the first check and be useless)
  * a real multi-line failure log ranks the latest failure first
"""
import os
import re
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "local"))
import diagnose  # noqa: E402

CLEAN_RUN = """\
==> Deploying /Users/friend/sites/mysite
  OK   clean, on main, up to date with origin (3f2a9c1d0e4b)
==> Local gates: npm ci, build, check
  OK   npm ci
  OK   build
check-dist OK: 6 pages, 31 files, 212 KB
  OK   pushed 3f2a9c1d0e4b
==> Deploying on homelab
deploying 3f2a9c1d0e4b (live now: 9c1b2d3e4f5a)
built mysite-site:3f2a9c1d0e4b
OK 3f2a9c1d0e4b is live on 127.0.0.1:8080 and proven (healthz 200, build:3f2a9c1d0e4b on the home page)
==> Verifying https://example.com serves 3f2a9c1d0e4b
verifying https://example.com
  OK   home page 200 (5120 bytes)
  OK   served as text/html; charset=utf-8
  OK   negative control: missing page answered 404
  OK   page contains "build:3f2a9c1d0e4b"
  OK   header content-security-policy
  OK   served through Cloudflare (DYNAMIC)
  OK   http:// redirects to https://
PASS https://example.com
  OK   live: https://example.com is 3f2a9c1d0e4b
   |- Currently banned:	0
audit: 0 fail, 1 warn
"""


def github_anchors(md):
    """Anchors GitHub generates for the headings in a Markdown file."""
    out = set()
    for h in re.findall(r"^#{1,6}\s+(.+?)\s*$", md, re.M):
        a = h.strip().lower()
        a = re.sub(r"[^\w\- ]", "", a)
        out.add(a.replace(" ", "-"))
    return out


class Diagnose(unittest.TestCase):
    def test_every_example_matches_its_own_entry_first(self):
        for e in diagnose.CATALOG:
            hits = diagnose.diagnose(e[6])
            self.assertTrue(hits, f"{e[0]}: its example matches nothing")
            self.assertEqual(hits[0][1][0], e[0], f"{e[0]}: its example diagnoses as {hits[0][1][0]}")

    def test_every_doc_anchor_exists(self):
        with open(os.path.join(ROOT, "docs", "TROUBLESHOOTING.md")) as fh:
            anchors = github_anchors(fh.read())
        for e in diagnose.CATALOG:
            self.assertIn(e[5], anchors, f"{e[0]}: docs/TROUBLESHOOTING.md has no section #{e[5]}")

    def test_every_owner_is_an_agent(self):
        agents = set(os.listdir(os.path.join(ROOT, ".claude", "skills")))
        for e in diagnose.CATALOG:
            self.assertIn(e[4], agents, f"{e[0]}: owner {e[4]} isn't an agent")

    def test_ids_are_unique(self):
        ids = [e[0] for e in diagnose.CATALOG]
        self.assertEqual(len(ids), len(set(ids)))

    def test_a_clean_run_matches_nothing(self):
        hits = diagnose.diagnose(CLEAN_RUN)
        self.assertEqual([h[1][0] for h in hits], [], "a successful run was diagnosed as a failure")

    def test_latest_failure_first(self):
        log = CLEAN_RUN + "FAIL /about/index.html: broken link /img/team.jpg\n" \
            + "FAIL the build of 3f2a9c1d0e4b failed (its own checks run inside it). 9c1b is still live, untouched.\n"
        ids = [h[1][0] for h in diagnose.diagnose(log)]
        self.assertEqual(ids[:2], ["build-failed", "broken-link"])

    def test_cli_exit_codes(self):
        script = os.path.join(ROOT, "scripts", "local", "diagnose.py")
        p = subprocess.run([sys.executable, script, "-"], input=CLEAN_RUN, capture_output=True, text=True)
        self.assertEqual(p.returncode, 3, p.stdout)
        self.assertIn("No known failure", p.stdout)
        p = subprocess.run([sys.executable, script, "-"], input="ssh: connect to host 10.0.0.9 port 22: Operation timed out\n",
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("fix:", p.stdout)
        self.assertIn("docs/TROUBLESHOOTING.md#the-server-doesnt-answer", p.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
