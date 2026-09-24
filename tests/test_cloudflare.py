#!/usr/bin/env python3
"""cf-tunnel.py and cf-domain.py against a fake Cloudflare API.

    python3 tests/test_cloudflare.py

What this proves, without a real account or card:
  * the tunnel is remotely managed, routed for apex + www, with a 404 fallback
  * both DNS records are PROXIED CNAMEs to <tunnel-id>.cfargotunnel.com
  * re-running changes nothing (idempotent)
  * an existing A record is never deleted without --replace-dns
  * a zone in another account is refused (Error 1014)
  * no token (API or tunnel) is ever printed; the tunnel token lands in a 600 file
  * a domain purchase: refused without a terminal, cancelled on a wrong answer,
    refused for premium, and only POSTed after the exact name is typed
"""
import os
import pty
import select
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import mock_cloudflare as mock  # noqa: E402

TUNNEL = os.path.join(ROOT, "scripts", "local", "cf-tunnel.py")
DOMAIN = os.path.join(ROOT, "scripts", "local", "cf-domain.py")


class Base(unittest.TestCase):
    zone_account = None

    def setUp(self):
        self.state = mock.State(zone_account=self.zone_account)
        self.srv, self.base = mock.start(self.state)
        self.home = tempfile.mkdtemp()
        self.cfg = os.path.join(self.home, "playbook.env")
        with open(self.cfg, "w") as fh:
            fh.write("SITE_NAME=mysite\nDOMAIN=example.org\nSITE_PORT=8080\nCF_ACCOUNT_ID=acct123\nSERVER_HOST=box\n")
        self.env = dict(os.environ, HOME=self.home, PLAYBOOK_ENV=self.cfg, CF_API_BASE=self.base,
                        CLOUDFLARE_API_TOKEN=mock.API_TOKEN, CF_POLL_SECONDS="0")

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()

    def run_cli(self, *args):
        p = subprocess.run([sys.executable, *args], env=self.env, capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=60)
        out = p.stdout + p.stderr
        self.assertNotIn(mock.API_TOKEN, out, "API token leaked to output")
        self.assertNotIn(mock.TUNNEL_TOKEN, out, "tunnel token leaked to output")
        return p.returncode, out

    def run_tty(self, args, answer):
        """Run with a real pseudo-terminal and type `answer` at the prompt."""
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(sys.executable, [sys.executable, *args], self.env)
        out, sent, deadline = b"", False, time.time() + 60
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            if not sent and b"Type the domain name" in out:
                os.write(fd, (answer + "\n").encode())
                sent = True
        _, status = os.waitpid(pid, 0)
        text = out.decode(errors="replace")
        self.assertNotIn(mock.API_TOKEN, text)
        return os.waitstatus_to_exitcode(status), text

    def posted(self, suffix):
        return [c for c in self.state.calls if c[0] == "POST" and c[1].endswith(suffix)]


class TunnelTests(Base):
    def test_create_routes_dns_and_saves_token(self):
        rc, out = self.run_cli(TUNNEL, "create")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.state.tunnels), 1)
        t = self.state.tunnels[0]
        self.assertEqual(t["config_src"], "cloudflare")
        ingress = self.state.config[t["id"]]["config"]["ingress"]
        self.assertEqual([r.get("hostname") for r in ingress], ["example.org", "www.example.org", None])
        self.assertEqual(ingress[0]["service"], "http://localhost:8080")
        self.assertEqual(ingress[-1]["service"], "http_status:404")
        self.assertEqual(sorted(r["name"] for r in self.state.dns), ["example.org", "www.example.org"])
        for r in self.state.dns:
            self.assertEqual(r["type"], "CNAME")
            self.assertEqual(r["content"], f"{t['id']}.cfargotunnel.com")
            self.assertIs(r["proxied"], True)
        path = os.path.join(self.home, ".config", "homelab-playbook", "tunnel-mysite.token")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        with open(path) as fh:
            self.assertEqual(fh.read().strip(), mock.TUNNEL_TOKEN)

    def test_rerun_is_idempotent(self):
        self.run_cli(TUNNEL, "create")
        before = len(self.state.calls)
        rc, out = self.run_cli(TUNNEL, "create")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.state.tunnels), 1)
        self.assertEqual(len(self.state.dns), 2)
        self.assertFalse([c for c in self.state.calls[before:] if c[0] == "POST"], "second run POSTed something")

    def test_existing_a_record_needs_explicit_replace(self):
        self.state.dns.append({"id": "old", "type": "A", "name": "example.org", "content": "192.0.2.1", "proxied": False})
        rc, out = self.run_cli(TUNNEL, "create")
        self.assertEqual(rc, 1)
        self.assertIn("--replace-dns", out)
        self.assertTrue(any(r["id"] == "old" for r in self.state.dns), "A record deleted without consent")
        rc, out = self.run_cli(TUNNEL, "create", "--replace-dns")
        self.assertEqual(rc, 0, out)
        self.assertFalse(any(r["type"] == "A" for r in self.state.dns))

    def test_bad_token_is_a_clean_error(self):
        self.env["CLOUDFLARE_API_TOKEN"] = "wrong"
        rc, out = self.run_cli(TUNNEL, "create")
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 403", out)
        self.assertNotIn("wrong", out.replace("wrong account", ""))


class CrossAccountTests(Base):
    zone_account = "someone-else"

    def test_zone_in_other_account_is_refused(self):
        rc, out = self.run_cli(TUNNEL, "create")
        self.assertEqual(rc, 1)
        self.assertIn("1014", out)
        self.assertEqual(self.state.tunnels, [])


class DomainTests(Base):
    def test_check_shows_price(self):
        rc, out = self.run_cli(DOMAIN, "check", "fresh-name.dev", "example.org")
        self.assertEqual(rc, 0, out)
        self.assertIn("AVAILABLE  fresh-name.dev", out)
        self.assertIn("10.11", out)
        self.assertIn("domain_unavailable", out)

    def test_register_refuses_without_terminal(self):
        rc, out = self.run_cli(DOMAIN, "register", "fresh-name.dev")
        self.assertNotEqual(rc, 0)
        self.assertIn("without a terminal", out)
        self.assertEqual(self.posted("/registrar/registrations"), [])

    def test_register_wrong_answer_cancels(self):
        rc, out = self.run_tty([DOMAIN, "register", "fresh-name.dev"], "yes")
        self.assertNotEqual(rc, 0)
        self.assertIn("Nothing was bought", out)
        self.assertEqual(self.posted("/registrar/registrations"), [])

    def test_register_premium_refused(self):
        rc, out = self.run_tty([DOMAIN, "register", "coffee.xyz"], "coffee.xyz")
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.posted("/registrar/registrations"), [])

    def test_register_typed_name_buys_with_auto_renew(self):
        rc, out = self.run_tty([DOMAIN, "register", "fresh-name.dev"], "fresh-name.dev")
        self.assertEqual(rc, 0, out)
        posts = self.posted("/registrar/registrations")
        self.assertEqual(len(posts), 1)
        body = posts[0][3]
        self.assertEqual(body["domain_name"], "fresh-name.dev")
        self.assertIs(body["auto_renew"], True)
        self.assertEqual(body["privacy_mode"], "redaction")
        self.assertIn("fresh-name.dev: active", out)
        self.assertIn("verification link", out)
        # It re-checked availability immediately before buying.
        checks = [i for i, c in enumerate(self.state.calls) if c[1].endswith("/domain-check")]
        self.assertTrue(checks and checks[-1] < self.state.calls.index(posts[0]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
