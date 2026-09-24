#!/usr/bin/env python3
"""Where you are in the playbook, probed live, and the one command to run next.

    ./playbook status            one line per phase, then "next:"
    ./playbook status --json     the same, for scripts
    ./playbook status --brief    only what isn't done, then "next:"

Every row is measured, not remembered: the laptop's tools and playbook.env,
one ssh round trip to the server (scripts/server/probe.sh: no sudo, changes
nothing), your domain at Cloudflare, and the live site through Cloudflare. The
server's own watch and audit results are read from the files its root timers
leave behind, so this never needs your sudo password.

A snapshot is saved for the Claude Code status line
(~/.local/state/homelab-playbook/status.json).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from cfapi import CFError, call, read_config  # noqa: E402

NAMES = ["laptop", "server", "harden", "domain", "site", "serve", "live", "ship", "watch"]
OWNERS = ["morpheus", "tank", "tank", "merovingian", "link", "tank", "trainman", "keeper", "sentinel"]
STEPS = ["ssh", "firewall", "fail2ban", "kernel", "docker", "updates"]


def ago(ts):
    s = max(0, int(time.time()) - int(ts))
    if s < 120:
        return f"{s}s ago"
    if s < 7200:
        return f"{s // 60}m ago"
    if s < 172800:
        return f"{s // 3600}h ago"
    return f"{s // 86400}d ago"


def run(cmd, timeout=30, stdin=None, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=stdin,
                           env=dict(os.environ, **(env or {})))
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 124, "", str(e)


def ssh_cmd(cfg):
    host = cfg.get("SERVER_HOST", "")
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "StrictHostKeyChecking=accept-new"]
    port = cfg.get("SSH_PORT", "22")
    if port and port != "22":
        cmd += ["-p", port]
    if "@" not in host and cfg.get("ADMIN_USER"):
        cmd += ["-l", cfg["ADMIN_USER"]]
    home = os.path.expanduser("~")
    # A 104+ byte socket path makes ssh refuse to run; %C alone is 40 bytes.
    if os.path.isdir(os.path.join(home, ".ssh")) and len(home) < 50:
        cmd += ["-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cm-hlp-%C", "-o", "ControlPersist=120"]
    return cmd + [host]


class Status:
    def __init__(self, cfg):
        self.cfg = cfg
        self.rows = []  # (phase, state, detail, next)

    def add(self, state, detail, nxt=""):
        self.rows.append({"phase": len(self.rows), "name": NAMES[len(self.rows)], "state": state,
                          "detail": detail, "next": nxt, "owner": OWNERS[len(self.rows)]})


def laptop(st, cfg, have_env):
    missing = [c for c in ("git", "ssh", "curl", "python3", "node", "npm") if not shutil.which(c)]
    if missing:
        return st.add("FAIL", "missing: " + " ".join(missing), f"install {' '.join(missing)} (PLAYBOOK.md Phase 0)")
    rc, out, _ = run(["node", "-p", "process.versions.node"])
    ver = out.strip()
    parts = [int(x) for x in re.findall(r"\d+", ver)[:2]] or [0, 0]
    if parts < [22, 12]:
        return st.add("FAIL", f"node {ver or '?'}; Astro needs 22.12 or newer", "install Node.js 22 LTS (https://nodejs.org)")
    if not have_env:
        return st.add("todo", "no playbook.env yet", "cp playbook.env.example playbook.env   (then fill it in)")
    rc, out, err = run(["bash", "-c", '. "$1/scripts/lib.sh"; load_config; validate_config', "_", ROOT])
    if rc != 0:
        first = next((l.strip() for l in (out + err).splitlines() if "FAIL" in l or "ERROR" in l), "playbook.env has a problem")
        return st.add("FAIL", re.sub(r"^\S*FAIL\S*\s*", "", first), "fix that line in playbook.env, then ./playbook status")
    blank = [k for k in ("SERVER_HOST", "ADMIN_USER", "SITE_NAME", "DOMAIN", "SITE_DIR", "SITE_MARKER") if not cfg.get(k)]
    if blank:
        return st.add("todo", "playbook.env: set " + " ".join(blank), "fill in playbook.env")
    st.add("done", f"tools ok, node {ver}, playbook.env valid")


def probe(cfg):
    host = cfg.get("SERVER_HOST", "")
    if not host or host == "192.0.2.10":
        return None, "SERVER_HOST isn't set yet"
    with open(os.path.join(ROOT, "scripts", "server", "probe.sh")) as fh:
        rc, out, err = run(ssh_cmd(cfg) + ["bash", "-s", "--", cfg.get("SITE_NAME", ""), cfg.get("SITE_PORT", "0"),
                                            cfg.get("TUNNEL_METRICS_PORT", "20241")], timeout=40, stdin=fh)
    if rc != 0:
        e = (err.strip().splitlines() or ["no answer"])[-1]
        return None, e
    return dict(l.split("=", 1) for l in out.splitlines() if "=" in l), ""


def domain_state(cfg):
    domain = cfg.get("DOMAIN", "")
    if not domain or domain == "example.com":
        return "todo", "no domain yet", "./playbook domain search \"what the site is about\"   (or ask: find me a domain)"
    acct = os.environ.get("CF_ACCOUNT_ID") or cfg.get("CF_ACCOUNT_ID")
    tok = os.path.expanduser("~/.config/homelab-playbook/cloudflare.token")
    if acct and (os.environ.get("CLOUDFLARE_API_TOKEN") or os.path.exists(tok)):
        try:
            _, p = call("GET", f"/accounts/{acct}/registrar/registrations/{domain}")
            r = p.get("result") or {}
            state = r.get("status", "?")
            detail = f"{domain}: {state}, auto-renew {'on' if r.get('auto_renew') else 'OFF'}, expires {str(r.get('expires_at', '?'))[:10]}"
            return ("done" if state == "active" else "FAIL"), detail, ("" if state == "active" else "./playbook domain status " + domain)
        except (CFError, SystemExit):
            pass  # not registered at Cloudflare, or the token can't read Registrar: fall back to DNS
    try:
        req = urllib.request.Request(f"https://cloudflare-dns.com/dns-query?name={domain}&type=NS",
                                     headers={"accept": "application/dns-json"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            ans = json.load(resp)
        ns = [a.get("data", "") for a in ans.get("Answer", []) if a.get("type") == 2]
        if any(n.rstrip(".").endswith("ns.cloudflare.com") for n in ns):
            return "done", f"{domain} uses Cloudflare's nameservers", ""
        if ns:
            return "FAIL", f"{domain}'s nameservers aren't Cloudflare's ({ns[0].rstrip('.')})", "move the domain's DNS to Cloudflare (docs/TROUBLESHOOTING.md#the-domain-doesnt-resolve)"
        return "todo", f"{domain} isn't registered yet", "./playbook domain check " + domain
    except (OSError, ValueError):
        return "skip", f"couldn't look up {domain} (offline?)", ""


def fetch_build(url):
    try:
        req = urllib.request.Request(url + "/", headers={"User-Agent": "homelab-playbook-status"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            m = re.search(r'name="build" content="build:([^"]+)"', resp.read(200000).decode("utf-8", "replace"))
            return m.group(1) if m else ""
    except (OSError, ValueError):
        return ""


def main(argv):
    as_json = "--json" in argv
    brief = "--brief" in argv
    env_path = os.environ.get("PLAYBOOK_ENV") or os.path.join(ROOT, "playbook.env")
    have_env = os.path.exists(env_path)
    cfg = read_config() if have_env else {}
    st = Status(cfg)

    laptop(st, cfg, have_env)
    facts, why = (None, "no playbook.env") if not have_env else probe(cfg)

    # 1 server
    if facts is None:
        if "Permission denied" in why:
            st.add("todo", f"the server answers but won't take your key ({why})", "./playbook server key")
        elif "isn't set" in why or not have_env:
            st.add("todo", why, "set SERVER_HOST in playbook.env (PLAYBOOK.md Phase 1)")
        else:
            st.add("FAIL", f"can't reach {cfg.get('SERVER_HOST')}: {why}", "is the server on? Check SERVER_HOST, then ./playbook why")
    else:
        st.add("done", f"{facts.get('user')}@{cfg.get('SERVER_HOST')} ({facts.get('os')})")

    # 2 harden
    if facts is None:
        st.add("skip", "needs the server", "")
    elif facts.get("bootstrapped") != "yes":
        st.add("todo", "not bootstrapped", "./playbook server bootstrap   (in your own terminal: it asks for your password)")
    else:
        done = [s for s in STEPS if facts.get("step_" + s) == "yes"]
        left = [s for s in STEPS if s not in done]
        audit = facts.get("audit_summary", "")
        m = re.search(r"audit: (\d+) fail, (\d+) warn", audit)
        if left:
            first = "./playbook server ssh" if "ssh" in left else "./playbook server harden"
            st.add("todo", "done: " + (" ".join(done) or "none") + "; left: " + " ".join(left),
                   first + "   (in your own terminal)")
        elif m and int(m.group(1)) > 0:
            st.add("FAIL", f"audit {ago(facts.get('audit_at', 0))}: {m.group(1)} fail. First: {facts.get('audit_first_fail', '?')}",
                   "./playbook server audit   (in your own terminal), then fix the FAIL lines")
        elif m:
            st.add("done", f"all six steps; audit {ago(facts.get('audit_at', 0))}: 0 fail, {m.group(2)} warn")
        else:
            st.add("done", "all six steps (no daily audit yet: ./playbook server watch sets one up)")

    # 3 domain
    st.add(*domain_state(cfg)) if have_env else st.add("skip", "needs playbook.env", "")

    # 4 site
    site_dir = os.path.expanduser(cfg.get("SITE_DIR", "")) if cfg.get("SITE_DIR") else ""
    local_head = ""
    if not site_dir or not os.path.isdir(os.path.join(site_dir, ".git")):
        st.add("todo", f"no site at {cfg.get('SITE_DIR') or 'SITE_DIR'} yet", "./playbook site new --theme midnight   (or ask: make my site)")
    else:
        rc, origin, _ = run(["git", "-C", site_dir, "remote", "get-url", "origin"])
        _, head, _ = run(["git", "-C", site_dir, "rev-parse", "--short=12", "HEAD"])
        local_head = head.strip()
        if rc != 0:
            st.add("todo", f"{cfg['SITE_DIR']} isn't on GitHub yet", f"cd {cfg['SITE_DIR']} && gh repo create {cfg.get('SITE_NAME', 'mysite')} --public --source . --push")
        elif "/you/" in cfg.get("SITE_REPO", "/you/") or not cfg.get("SITE_REPO"):
            st.add("todo", f"GitHub repo exists ({origin.strip()}) but SITE_REPO isn't set", "set SITE_REPO in playbook.env to " + origin.strip())
        else:
            st.add("done", f"{cfg['SITE_DIR']} -> {origin.strip()}")

    # 5 serve
    if facts is None:
        st.add("skip", "needs the server", "")
    elif facts.get("site_checkout") != "yes":
        st.add("todo", "the site isn't on the server yet", "./playbook server site")
    elif facts.get("site_healthz") != "200":
        st.add("FAIL", f"127.0.0.1:{cfg.get('SITE_PORT')} answers {facts.get('site_healthz')} on /healthz", "./playbook server site   (then ./playbook why if it fails)")
    else:
        st.add("done", f"127.0.0.1:{cfg.get('SITE_PORT')} healthy, build {facts.get('site_build') or '?'}")

    # 6 live
    domain = cfg.get("DOMAIN", "")
    live_build = ""
    if facts is not None and facts.get("tunnel_installed") != "yes":
        st.add("todo", "no tunnel yet", "./playbook server tunnel")
    elif not domain or domain == "example.com":
        st.add("skip", "needs a domain", "")
    else:
        # LIVE_URL is for the test suite; your site is https://DOMAIN.
        live = os.environ.get("LIVE_URL") or f"https://{domain}"
        rc, out, err = run([os.path.join(ROOT, "scripts", "verify-site.sh"), live, cfg.get("SITE_MARKER", "")], timeout=90)
        fails = [l.strip()[5:] for l in out.splitlines() if l.strip().startswith("FAIL ") and not l.startswith("FAIL http")]
        if rc == 0:
            live_build = fetch_build(live)
            st.add("done", f"{live} verified (status, negative control, marker, headers)")
        elif rc == 3:
            st.add("skip", f"{live}: a Cloudflare challenge blocked the check (inconclusive)", "")
        else:
            tunnel = "" if facts is None else f"; connector ready: {'yes' if facts.get('tunnel_ready') == '200' else 'NO'}"
            st.add("FAIL", f"{live}: {fails[0] if fails else 'check failed'}{tunnel}", "./playbook why")

    # 7 ship
    if not live_build or not local_head:
        st.add("skip", "needs a live site and a local site", "")
    elif live_build == local_head:
        st.add("done", f"live is your main ({live_build})")
    else:
        rc, _, _ = run(["git", "-C", site_dir, "merge-base", "--is-ancestor", live_build, "HEAD"])
        if rc == 0:
            _, n, _ = run(["git", "-C", site_dir, "rev-list", "--count", f"{live_build}..HEAD"])
            st.add("todo", f"live is {live_build}; your main has {n.strip()} newer commit(s)", "./playbook deploy")
        else:
            st.add("todo", f"live is {live_build}, your main is {local_head}", "./playbook deploy   (or git pull, if GitHub is ahead)")

    # 8 watch
    if facts is None:
        st.add("skip", "needs the server", "")
    elif facts.get("timer_watch") != "enabled":
        st.add("todo", "the server isn't watching itself yet", "./playbook server watch   (in your own terminal)")
    else:
        res = facts.get("watch_result", "")
        at = int(facts.get("watch_at", "0") or 0)
        extra = []
        if facts.get("timer_autodeploy") == "enabled":
            extra.append("auto-deploy on" + (" (PAUSED after a rollback)" if facts.get("autodeploy_paused") == "yes" else ""))
        if facts.get("reboot_pending") == "yes":
            extra.append("reboot pending")
        tail = ("; " + ", ".join(extra)) if extra else ""
        if res.startswith("FAIL"):
            st.add("FAIL", f"watch {ago(at)}: {res[5:]}{tail}", "./playbook why")
        elif at and time.time() - at > 1800:
            st.add("FAIL", f"the watch last ran {ago(at)} (every 10 min expected){tail}", "./playbook server audit")
        else:
            st.add("done", f"watch {ago(at) if at else 'never'}: {res or 'no result yet'}{tail}")

    current = next((r for r in st.rows if r["state"] in ("FAIL", "todo")), None)
    snap = {"at": int(time.time()), "rows": st.rows, "current": current,
            "next": current["next"] if current else ""}
    state_dir = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "homelab-playbook")
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(os.path.join(state_dir, "status.json"), "w") as fh:
            json.dump(snap, fh)
    except OSError:
        pass

    if as_json:
        print(json.dumps(snap, indent=2))
    else:
        for r in st.rows:
            if brief and r["state"] == "done":
                continue
            print(f"  {r['phase']} {r['name']:<7}{r['state']:<5} {r['detail']}")
        if current:
            print(f"next: {current['next']}   (phase {current['phase']}, {current['owner']})")
        else:
            print("next: nothing. Every phase is done and verified. Edit, commit, ./playbook deploy.")
    return 1 if any(r["state"] == "FAIL" for r in st.rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
