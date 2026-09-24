#!/usr/bin/env python3
"""`./playbook status` (scripts/local/status.py) reports what's true, and names
the right next command, from a blank laptop to a finished setup.

    python3 tests/test_status.py

The server is an `ssh` stub that answers with canned probe.sh facts (probe.sh
itself runs for real in tests/linux/smoke-scripts.sh), Cloudflare is the mock
API, and the live site is a local server with the real headers. Every scenario
asserts both the state and the `next:` command, because the command is what a
friend (or their agent) actually runs.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import mock_cloudflare as mock  # noqa: E402

STATUS = os.path.join(ROOT, "scripts", "local", "status.py")
STATUSLINE = os.path.join(ROOT, ".claude", "statusline.py")
MARKER = "Hello from the status test"
ACCOUNT = "0123456789abcdef0123456789abcdef"

ALL_GOOD = {
    "os": "Ubuntu 24.04.1 LTS", "user": "friend", "playbook": "yes", "bootstrapped": "yes", "sudo_group": "yes",
    "step_ssh": "yes", "step_firewall": "yes", "step_fail2ban": "yes", "step_kernel": "yes", "step_docker": "yes",
    "step_updates": "yes", "docker_access": "yes", "reboot_pending": "no", "disk_pct": "31",
    "site_checkout": "yes", "site_healthz": "200", "tunnel_installed": "yes", "tunnel_ready": "200",
    "autodeploy_paused": "no", "timer_watch": "enabled", "timer_audit": "enabled", "timer_autodeploy": "disabled",
    "watch_result": "ok mysite", "audit_summary": "audit: 0 fail, 1 warn", "audit_first_fail": "",
    "watch_at": str(int(time.time()) - 120), "audit_at": str(int(time.time()) - 3600),
}


class Site:
    def __init__(self, build):
        site = self
        self.build = build

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                home = self.path == "/"
                body = (f'<html><head><meta name="build" content="build:{site.build}"></head>'
                        f"<body><h1>{MARKER}</h1></body></html>") if home else "nope"
                self.send_response(200 if home else 404)
                self.send_header("Content-Type", "text/html")
                for h in ("Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy", "Permissions-Policy"):
                    self.send_header(h, "x")
                self.end_headers()
                self.wfile.write(body.encode())

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "node"), "w") as fh:
            fh.write("#!/bin/sh\necho 22.12.0\n")
        with open(os.path.join(self.bin, "npm"), "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        # ssh: swallow the probe script on stdin, answer with the scenario's facts.
        with open(os.path.join(self.bin, "ssh"), "w") as fh:
            fh.write('#!/bin/sh\ncat >/dev/null\n[ -n "$STUB_ERR" ] && echo "$STUB_ERR" >&2\n'
                     '[ -f "$STUB_FACTS" ] && cat "$STUB_FACTS"\nexit "${STUB_RC:-0}"\n')
        for f in ("node", "npm", "ssh"):
            os.chmod(os.path.join(self.bin, f), 0o755)
        self.state = mock.State(account=ACCOUNT)
        self.state.registrations["example.org"] = {"domain_name": "example.org", "status": "active", "auto_renew": True,
                                                   "expires_at": "2027-09-23T00:00:00Z"}
        self.cf, self.cf_base = mock.start(self.state)
        self.site_dir = os.path.join(self.tmp, "site")
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@e")
        subprocess.run(["git", "init", "-q", "-b", "main", self.site_dir], check=True, env=env)
        subprocess.run(["git", "-C", self.site_dir, "commit", "-q", "--allow-empty", "-m", "x"], check=True, env=env)
        subprocess.run(["git", "-C", self.site_dir, "remote", "add", "origin", "https://github.com/friend/mysite.git"], check=True)
        self.head = subprocess.run(["git", "-C", self.site_dir, "rev-parse", "--short=12", "HEAD"], capture_output=True,
                                   text=True, check=True).stdout.strip()
        self.env_file = os.path.join(self.tmp, "playbook.env")
        self.site = None

    def tearDown(self):
        self.cf.shutdown()
        self.cf.server_close()
        if self.site:
            self.site.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_env(self, **over):
        cfg = {"SERVER_HOST": "homelab", "ADMIN_USER": "friend", "SSH_PORT": "22", "SITE_NAME": "mysite",
               "DOMAIN": "example.org", "SITE_DIR": self.site_dir, "SITE_REPO": "https://github.com/friend/mysite.git",
               "SITE_PORT": "8080", "SITE_MARKER": f'"{MARKER}"', "CF_ACCOUNT_ID": ACCOUNT, "REBOOT_TIME": "04:30"}
        cfg.update(over)
        with open(self.env_file, "w") as fh:
            fh.write("".join(f"{k}={v}\n" for k, v in cfg.items()))

    def status(self, facts=None, rc=0, err="", live_build=None, env_file=True):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], HOME=self.tmp,
                   XDG_STATE_HOME=os.path.join(self.tmp, "state"), CF_API_BASE=self.cf_base,
                   CLOUDFLARE_API_TOKEN=mock.API_TOKEN, STUB_RC=str(rc), STUB_ERR=err,
                   PLAYBOOK_ENV=self.env_file if env_file else os.path.join(self.tmp, "missing.env"))
        if facts is not None:
            path = os.path.join(self.tmp, "facts")
            with open(path, "w") as fh:
                fh.write("".join(f"{k}={v}\n" for k, v in facts.items()))
            env["STUB_FACTS"] = path
        if live_build:
            self.site = Site(live_build)
            env["LIVE_URL"] = self.site.url
        p = subprocess.run([sys.executable, STATUS, "--json"], capture_output=True, text=True, env=env, timeout=120)
        try:
            snap = json.loads(p.stdout)
        except ValueError:
            self.fail(f"status --json printed no JSON: {p.stdout} {p.stderr}")
        rows = {r["name"]: r for r in snap["rows"]}
        return p.returncode, rows, snap, env

    def test_no_playbook_env(self):
        rc, rows, snap, _ = self.status(env_file=False)
        self.assertEqual(rows["laptop"]["state"], "todo")
        self.assertIn("cp playbook.env.example playbook.env", snap["next"])

    def test_invalid_playbook_env_names_the_line(self):
        self.write_env(SITE_NAME='"My Site"')
        rc, rows, snap, _ = self.status(facts=ALL_GOOD, live_build="x")
        self.assertEqual(rows["laptop"]["state"], "FAIL")
        self.assertIn("SITE_NAME", rows["laptop"]["detail"])
        self.assertEqual(rc, 1)

    def test_key_refused_points_at_server_key(self):
        self.write_env()
        rc, rows, snap, _ = self.status(rc=255, err="friend@homelab: Permission denied (publickey).")
        self.assertEqual(rows["server"]["state"], "todo")
        self.assertEqual(snap["current"]["name"], "server")
        self.assertIn("./playbook server key", snap["next"])

    def test_half_hardened_points_at_harden(self):
        self.write_env()
        facts = dict(ALL_GOOD, step_firewall="no", step_docker="no", step_updates="no")
        rc, rows, snap, _ = self.status(facts=facts, live_build=self.head)
        self.assertEqual(rows["harden"]["state"], "todo")
        self.assertIn("left: firewall docker updates", rows["harden"]["detail"])
        self.assertIn("./playbook server harden", snap["next"])

    def test_everything_done(self):
        self.write_env()
        rc, rows, snap, env = self.status(facts=ALL_GOOD, live_build=self.head)
        self.assertEqual(rc, 0, json.dumps(rows, indent=1))
        not_done = {n: r for n, r in rows.items() if r["state"] != "done"}
        self.assertEqual(not_done, {}, json.dumps(not_done, indent=1))
        self.assertIsNone(snap["current"])
        # The status line reads the snapshot this run saved.
        p = subprocess.run([sys.executable, STATUSLINE], input='{"context_window":{"used_percentage":40}}',
                           capture_output=True, text=True, env=env)
        self.assertIn("all phases done", p.stdout)
        self.assertIn("ctx 40%", p.stdout)

    def test_watch_failure_is_a_fail(self):
        self.write_env()
        facts = dict(ALL_GOOD, watch_result="FAIL mysite: origin: healthz 000, home 000")
        rc, rows, snap, _ = self.status(facts=facts, live_build=self.head)
        self.assertEqual(rows["watch"]["state"], "FAIL")
        self.assertEqual(rc, 1)

    def test_live_behind_main_says_deploy(self):
        self.write_env()
        rc, rows, snap, env = self.status(facts=ALL_GOOD, live_build="000000000000")
        self.assertEqual(rows["ship"]["state"], "todo")
        self.assertIn("./playbook deploy", rows["ship"]["next"])
        p = subprocess.run([sys.executable, STATUSLINE], input="{}", capture_output=True, text=True, env=env)
        self.assertIn("playbook 7/8 ship todo", p.stdout)

    def test_site_down_on_server(self):
        self.write_env()
        rc, rows, snap, _ = self.status(facts=dict(ALL_GOOD, site_healthz="000"), live_build=self.head)
        self.assertEqual(rows["serve"]["state"], "FAIL")
        self.assertIn("./playbook server site", rows["serve"]["next"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
