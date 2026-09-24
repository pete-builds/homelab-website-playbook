"""A small, stateful fake of the Cloudflare API endpoints this repo calls.

It records every request so tests can assert what was (and was not) sent, and
it rejects any request without the expected bearer token.
"""
import json
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

API_TOKEN = "test-api-token-DO-NOT-PRINT"
TUNNEL_TOKEN = "eyTEST-tunnel-token-DO-NOT-PRINT"


class State:
    def __init__(self, account="acct123", zone_account=None):
        self.account = account
        self.zones = [{"id": "zone1", "name": "example.org", "account": {"id": zone_account or account, "name": "Friend"}}]
        self.tunnels = []
        self.config = {}
        self.dns = []
        self.registrations = {}
        self.status_polls = 0
        self.calls = []
        self.availability = {
            "example.org": {"name": "example.org", "registrable": False, "reason": "domain_unavailable"},
            "fresh-name.dev": {"name": "fresh-name.dev", "registrable": True, "tier": "standard",
                               "pricing": {"currency": "USD", "registration_cost": "10.11", "renewal_cost": "10.11"}},
            # registrable but premium: exercises the tier check, not the availability check
            "coffee.xyz": {"name": "coffee.xyz", "registrable": True, "tier": "premium",
                           "pricing": {"currency": "USD", "registration_cost": "2500.00", "renewal_cost": "2500.00"}},
            "noprice.dev": {"name": "noprice.dev", "registrable": True, "tier": "standard"},
            "mine-already.dev": {"name": "mine-already.dev", "registrable": True, "tier": "standard",
                                 "pricing": {"currency": "USD", "registration_cost": "10.11", "renewal_cost": "10.11"}},
        }


def make_handler(state):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, result=None, errors=None):
            body = {"success": code < 400, "errors": errors or [], "messages": [], "result": result}
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _handle(self, method):
            u = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"null") if n else None
            path = u.path.replace("/client/v4", "", 1)
            state.calls.append((method, path, q, body))
            if self.headers.get("Authorization") != "Bearer " + API_TOKEN:
                return self._send(403, errors=[{"code": 10000, "message": "Authentication error"}])
            acct = state.account

            if method == "GET" and path == "/zones":
                return self._send(200, [z for z in state.zones if z["name"] == q.get("name")])

            m = re.fullmatch(rf"/accounts/{acct}/cfd_tunnel", path)
            if m and method == "GET":
                return self._send(200, [t for t in state.tunnels if t["name"] == q.get("name")])
            if m and method == "POST":
                t = {"id": str(uuid.uuid4()), "name": body["name"], "status": "inactive", "connections": [],
                     "config_src": body.get("config_src")}
                state.tunnels.append(t)
                return self._send(200, t)
            m = re.fullmatch(rf"/accounts/{acct}/cfd_tunnel/([^/]+)/configurations", path)
            if m and method == "PUT":
                state.config[m.group(1)] = body
                return self._send(200, body)
            if m and method == "GET":
                return self._send(200, state.config.get(m.group(1), {}))
            m = re.fullmatch(rf"/accounts/{acct}/cfd_tunnel/([^/]+)/token", path)
            if m and method == "GET":
                return self._send(200, TUNNEL_TOKEN)

            m = re.fullmatch(r"/zones/([^/]+)/dns_records", path)
            if m and method == "GET":
                return self._send(200, [r for r in state.dns if r["name"] == q.get("name")])
            if m and method == "POST":
                if any(r["name"] == body["name"] for r in state.dns):
                    return self._send(400, errors=[{"code": 81057, "message": "record already exists"}])
                rec = dict(body, id=str(uuid.uuid4()))
                state.dns.append(rec)
                return self._send(200, rec)
            m = re.fullmatch(r"/zones/([^/]+)/dns_records/([^/]+)", path)
            if m and method in ("PUT", "DELETE"):
                state.dns = [r for r in state.dns if r["id"] != m.group(2)]
                if method == "PUT":
                    state.dns.append(dict(body, id=m.group(2)))
                return self._send(200, {"id": m.group(2)})

            if path == f"/accounts/{acct}/registrar/domain-check" and method == "POST":
                return self._send(200, {"domains": [state.availability.get(d, {"name": d, "registrable": False,
                                                    "reason": "extension_not_supported_via_api"}) for d in body["domains"]]})
            if path == f"/accounts/{acct}/registrar/domain-search" and method == "GET":
                return self._send(200, {"domains": [v for v in state.availability.values()]})
            if path == f"/accounts/{acct}/registrar/registrations" and method == "POST":
                d = body["domain_name"]
                state.registrations[d] = {"domain_name": d, "status": "pending", "auto_renew": body.get("auto_renew"),
                                          "privacy_mode": body.get("privacy_mode"), "locked": True,
                                          "expires_at": "2027-09-23T00:00:00Z"}
                return self._send(202, {"state": "in_progress", "completed": False, "context": {"domain_name": d}})
            m = re.fullmatch(rf"/accounts/{acct}/registrar/registrations/([^/]+)/registration-status", path)
            if m and method == "GET":
                state.status_polls += 1
                if state.status_polls < 2:
                    return self._send(200, {"state": "in_progress", "completed": False})
                state.registrations[m.group(1)]["status"] = "active"
                return self._send(200, {"state": "succeeded", "completed": True})
            m = re.fullmatch(rf"/accounts/{acct}/registrar/registrations/([^/]+)", path)
            if m and method == "GET":
                r = state.registrations.get(m.group(1))
                return self._send(200, r) if r else self._send(404, errors=[{"code": 404, "message": "not found"}])

            return self._send(404, errors=[{"code": 7003, "message": f"mock has no route {method} {path}"}])

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

        def do_PUT(self):
            self._handle("PUT")

        def do_DELETE(self):
            self._handle("DELETE")

    return H


class _Server(ThreadingHTTPServer):
    # HTTPServer.server_bind does a reverse-DNS lookup (socket.getfqdn) that can
    # hang for ~35s on a laptop with slow DNS. The mock doesn't need a name.
    def server_bind(self):
        import socketserver

        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


def start(state):
    srv = _Server(("127.0.0.1", 0), make_handler(state))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}/client/v4"
