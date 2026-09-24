#!/usr/bin/env python3
"""scripts/verify-site.sh against a local server that can be every kind of wrong.

    python3 tests/test_verify_site.py

verify-site.sh is the check every other check leans on (deploys, the watch,
status, the uptime workflow), so each way a site can look up while being
broken gets a server built to do exactly that, and the verifier has to say
FAIL. The controls run the other way: a healthy site must PASS, and a normal
page that merely contains Cloudflare's injected challenge-platform script
must NOT read as a challenge.
"""
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(ROOT, "scripts", "verify-site.sh")
MARKER = "Hello from the verify test"
HEADERS = {
    "Content-Security-Policy": "default-src 'self'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "Permissions-Policy": "geolocation=()",
}
PAGE = f'<!doctype html><html><head><meta name="build" content="build:abc123"></head><body><h1>{MARKER}</h1></body></html>'


class Site:
    """mode: good | catchall | octet | noheader | challenge | injected | wrongpage"""

    def __init__(self, mode):
        site = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                m = site.mode
                if m == "challenge":
                    body = b"<html><head><title>Just a moment...</title></head></html>"
                    self.send_response(403)
                    self.send_header("cf-mitigated", "challenge")
                    self.send_header("Content-Type", "text/html")
                    self.end_headers()
                    return self.wfile.write(body)
                home = self.path == "/"
                if not home and m != "catchall":
                    self.send_response(404)
                    self.send_header("Content-Type", "text/html")
                    for k, v in HEADERS.items():
                        self.send_header(k, v)
                    self.end_headers()
                    return self.wfile.write(b"not found")
                body = PAGE
                if m == "injected":
                    body = PAGE.replace("</body>", '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script></body>')
                if m == "wrongpage":
                    body = "<html><body>Someone else's site</body></html>"
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream" if m == "octet" else "text/html; charset=utf-8")
                for k, v in HEADERS.items():
                    if m == "noheader" and k == "Permissions-Policy":
                        continue
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body.encode())

        self.mode = mode
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def verify(url, marker=MARKER):
    p = subprocess.run([VERIFY, url, marker], capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr


class VerifySite(unittest.TestCase):
    def check(self, mode, want_rc, want_text, marker=MARKER):
        s = Site(mode)
        try:
            rc, out = verify(s.url, marker)
        finally:
            s.close()
        self.assertEqual(rc, want_rc, out)
        self.assertIn(want_text, out)
        return out

    def test_healthy_site_passes(self):
        out = self.check("good", 0, "PASS")
        self.assertIn("negative control", out)

    def test_build_id_is_a_marker(self):
        self.check("good", 0, "PASS", marker="build:abc123")
        self.check("good", 1, 'does NOT contain "build:zzz999"', marker="build:zzz999")

    def test_catch_all_server_fails_the_negative_control(self):
        self.check("catchall", 1, "The server answers everything")

    def test_html_served_as_a_download_fails(self):
        self.check("octet", 1, "not text/html")

    def test_missing_security_header_fails(self):
        self.check("noheader", 1, "header permissions-policy missing")

    def test_wrong_page_fails_the_marker(self):
        self.check("wrongpage", 1, "does NOT contain")

    def test_challenge_is_indeterminate_not_up_or_down(self):
        self.check("challenge", 3, "INDETERMINATE")

    def test_injected_challenge_script_is_not_a_challenge(self):
        # Control for the one above: Cloudflare injects this into NORMAL pages.
        self.check("injected", 0, "PASS")

    def test_nothing_listening_fails(self):
        s = Site("good")
        url = s.url
        s.close()
        rc, out = verify(url)
        self.assertEqual(rc, 1, out)
        self.assertIn("no answer at all", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
