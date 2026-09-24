"""Tiny Cloudflare API client shared by cf-domain.py and cf-tunnel.py.

Standard library only. The API token is read from, in order:
  1. $CLOUDFLARE_API_TOKEN
  2. ~/.config/homelab-playbook/cloudflare.token  (must be mode 600)
It is sent in the Authorization header and never printed, logged, or put in
an exception message.

$CF_API_BASE overrides the endpoint; the test suite points it at a local mock.
"""
import json
import os
import stat
import sys
import urllib.error
import urllib.request

API_BASE = os.environ.get("CF_API_BASE", "https://api.cloudflare.com/client/v4").rstrip("/")
TOKEN_FILE = os.path.expanduser("~/.config/homelab-playbook/cloudflare.token")
CONFIG_FILE = os.environ.get(
    "PLAYBOOK_ENV",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "playbook.env"),
)


class CFError(Exception):
    pass


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_config():
    """Parse playbook.env (KEY=value lines, optional quotes)."""
    cfg = {}
    try:
        with open(CONFIG_FILE) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return cfg


def token():
    tok = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
    if tok:
        return tok
    if not os.path.exists(TOKEN_FILE):
        die(
            "no Cloudflare API token. Create one (see PLAYBOOK.md, Phase 3), then:\n"
            f"  mkdir -p {os.path.dirname(TOKEN_FILE)} && (umask 077; pbpaste > {TOKEN_FILE})\n"
            "  (on Linux, paste it with: umask 077; cat > the-file, then Ctrl-D)"
        )
    mode = stat.S_IMODE(os.stat(TOKEN_FILE).st_mode)
    if mode & 0o077:
        die(f"{TOKEN_FILE} is mode {oct(mode)[2:]}; run: chmod 600 {TOKEN_FILE}")
    with open(TOKEN_FILE) as fh:
        tok = fh.read().strip()
    if not tok:
        die(f"{TOKEN_FILE} is empty")
    return tok


def account_id(cli_value=None):
    acct = cli_value or os.environ.get("CF_ACCOUNT_ID") or read_config().get("CF_ACCOUNT_ID", "")
    if not acct:
        die("set CF_ACCOUNT_ID in playbook.env (dashboard: the Account ID in the right sidebar)")
    return acct


def call(method, path, body=None, query=None, headers=None):
    """Return (http_status, parsed_json). Raises CFError with Cloudflare's own
    error messages on a non-2xx response or success:false."""
    url = API_BASE + path
    if query:
        from urllib.parse import urlencode

        url += "?" + urlencode(query, doseq=True)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except urllib.error.URLError as e:
        raise CFError(f"{method} {path}: cannot reach Cloudflare ({e.reason})")
    try:
        payload = json.loads(raw or b"{}")
    except ValueError:
        raise CFError(f"{method} {path}: HTTP {status}, response was not JSON")
    if status >= 400 or payload.get("success") is False:
        errs = "; ".join(f"{e.get('code')}: {e.get('message')}" for e in payload.get("errors", [])) or "no detail"
        hint = ""
        if status in (401, 403) or "9109" in errs or "10000" in errs:
            hint = "\n  (token invalid, expired, or missing a permission; see PLAYBOOK.md Phase 3)"
        raise CFError(f"{method} {path}: HTTP {status}: {errs}{hint}")
    return status, payload
