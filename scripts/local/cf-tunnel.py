#!/usr/bin/env python3
"""Create (or repair) the Cloudflare Tunnel that publishes your site.

    cf-tunnel.py create [--replace-dns]    tunnel + ingress + DNS, token saved to a 600 file
    cf-tunnel.py status                    is it connected, routed, and resolvable?

Reads SITE_NAME, DOMAIN, SITE_PORT and CF_ACCOUNT_ID from playbook.env.
Idempotent: re-running reuses the tunnel and fixes whatever drifted.

What "create" does, in the order that avoids every trap in TROUBLESHOOTING.md:
  1. Finds the zone for DOMAIN and checks it's in the SAME account as the tunnel
     (different accounts = Error 1014).
  2. Reuses the tunnel named SITE_NAME, or creates it (remotely managed, so the
     ingress lives in Cloudflare and the server needs only a token).
  3. Sets the ingress: DOMAIN and www.DOMAIN -> http://localhost:SITE_PORT,
     everything else -> 404. (No ingress = the tunnel is "healthy" and serves 503.)
  4. Creates PROXIED CNAMEs for both names -> <tunnel-id>.cfargotunnel.com.
     A tunnel "hostname route" is NOT a DNS record, and an unproxied CNAME to
     cfargotunnel.com does not resolve.
  5. Saves the run token to ~/.config/homelab-playbook/tunnel-<site>.token
     (mode 600). The token is never printed.

API token needs: Account > Cloudflare Tunnel > Edit, Zone > DNS > Edit, Zone > Zone > Read.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cfapi import CFError, account_id, call, read_config  # noqa: E402

TOKEN_DIR = os.path.expanduser("~/.config/homelab-playbook")


def settings():
    cfg = read_config()
    for k in ("SITE_NAME", "DOMAIN", "SITE_PORT"):
        cfg[k] = os.environ.get(k, cfg.get(k, ""))
        if not cfg[k]:
            sys.exit(f"ERROR: set {k} in playbook.env")
    return cfg


def zone_for(acct, domain):
    _, p = call("GET", "/zones", query={"name": domain})
    zones = p["result"]
    if not zones:
        sys.exit(
            f"ERROR: no Cloudflare zone for {domain}. If you registered it at Cloudflare it appears\n"
            "automatically; if it's registered elsewhere, add it as a site and switch its nameservers first."
        )
    z = zones[0]
    if z.get("account", {}).get("id") not in (None, acct):
        sys.exit(
            f"ERROR: {domain} lives in a different Cloudflare account ({z['account'].get('name')}).\n"
            "A tunnel in one account can't serve a zone in another (Error 1014). Use one account for both."
        )
    return z["id"]


def find_tunnel(acct, name):
    _, p = call("GET", f"/accounts/{acct}/cfd_tunnel", query={"name": name, "is_deleted": "false"})
    return p["result"][0] if p["result"] else None


def ensure_tunnel(acct, name):
    t = find_tunnel(acct, name)
    if t:
        print(f"  OK   tunnel '{name}' exists ({t['id']})")
        return t
    _, p = call("POST", f"/accounts/{acct}/cfd_tunnel", {"name": name, "config_src": "cloudflare"})
    print(f"  OK   created tunnel '{name}' ({p['result']['id']})")
    return p["result"]


def ensure_ingress(acct, tid, hosts, port):
    origin = f"http://localhost:{port}"
    ingress = [{"hostname": h, "service": origin} for h in hosts] + [{"service": "http_status:404"}]
    call("PUT", f"/accounts/{acct}/cfd_tunnel/{tid}/configurations", {"config": {"ingress": ingress}})
    print(f"  OK   ingress: {', '.join(hosts)} -> {origin}; everything else -> 404")


def ensure_dns(zone, host, target, replace):
    _, p = call("GET", f"/zones/{zone}/dns_records", query={"name": host})
    recs = p["result"]
    want = {"type": "CNAME", "name": host, "content": target, "proxied": True, "ttl": 1,
            "comment": "Cloudflare Tunnel (homelab-website-playbook)"}
    cname = [r for r in recs if r["type"] == "CNAME"]
    others = [r for r in recs if r["type"] in ("A", "AAAA")]
    if others and not replace:
        kinds = ", ".join(f"{r['type']} {r['content']}" for r in others)
        sys.exit(
            f"ERROR: {host} already has {kinds}. A name can't have both those and a CNAME.\n"
            "If that's an old parking/placeholder record, re-run with --replace-dns to delete it."
        )
    for r in others:
        call("DELETE", f"/zones/{zone}/dns_records/{r['id']}")
        print(f"  OK   deleted {r['type']} {host} -> {r['content']} (--replace-dns)")
    if cname:
        r = cname[0]
        if r["content"] == target and r.get("proxied"):
            print(f"  OK   DNS {host} -> tunnel (proxied)")
            return
        if r["content"] != target and not replace:
            sys.exit(f"ERROR: {host} is a CNAME to {r['content']}. Re-run with --replace-dns to point it at the tunnel.")
        call("PUT", f"/zones/{zone}/dns_records/{r['id']}", want)
        print(f"  OK   DNS {host} updated -> tunnel (proxied)")
        return
    call("POST", f"/zones/{zone}/dns_records", want)
    print(f"  OK   DNS {host} -> tunnel (proxied)")


def save_token(acct, tid, site):
    _, p = call("GET", f"/accounts/{acct}/cfd_tunnel/{tid}/token")
    tok = p["result"]
    os.makedirs(TOKEN_DIR, mode=0o700, exist_ok=True)
    path = os.path.join(TOKEN_DIR, f"tunnel-{site}.token")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(tok + "\n")
    os.chmod(path, 0o600)
    print(f"  OK   tunnel token saved to {path} (600, not shown)")
    return path


def cmd_create(a, cfg):
    acct, site, domain = a.acct, cfg["SITE_NAME"], cfg["DOMAIN"]
    hosts = [domain, f"www.{domain}"]
    print(f"Tunnel for {domain} (site '{site}')")
    zone = zone_for(acct, domain)
    t = ensure_tunnel(acct, site)
    ensure_ingress(acct, t["id"], hosts, cfg["SITE_PORT"])
    for h in hosts:
        ensure_dns(zone, h, f"{t['id']}.cfargotunnel.com", a.replace_dns)
    path = save_token(acct, t["id"], site)
    host = cfg.get("SERVER_HOST", "<server>")
    port = cfg.get("SSH_PORT", "22")
    if port and port != "22":
        host = f"-p {port} {host}"
    print(f"""
Next, install the connector on the server (the token travels over SSH stdin,
never as an argument):

  ssh {host} 'cd ~/homelab-website-playbook && ./scripts/server/80-tunnel.sh' < {path}
""")


def cmd_status(a, cfg):
    acct, site, domain = a.acct, cfg["SITE_NAME"], cfg["DOMAIN"]
    t = find_tunnel(acct, site)
    if not t:
        sys.exit(f"no tunnel named '{site}'. Run: cf-tunnel.py create")
    conns = t.get("connections") or []
    print(f"tunnel {site} ({t['id']}): status={t.get('status')}, {len(conns)} connection(s)")
    _, p = call("GET", f"/accounts/{acct}/cfd_tunnel/{t['id']}/configurations")
    for rule in (p["result"].get("config") or {}).get("ingress", []):
        print(f"  ingress {rule.get('hostname', '*'):<30} -> {rule['service']}")
    zone = zone_for(acct, domain)
    for h in (domain, f"www.{domain}"):
        _, d = call("GET", f"/zones/{zone}/dns_records", query={"name": h})
        recs = ", ".join(f"{r['type']} {r['content']} proxied={r.get('proxied')}" for r in d["result"]) or "NONE"
        print(f"  dns     {h:<30} {recs}")
    if t.get("status") != "healthy":
        print("\nNot healthy: the connector isn't running. On the server: docker logs cloudflared-" + site)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--account", help="Cloudflare account ID (default: CF_ACCOUNT_ID in playbook.env)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--replace-dns", action="store_true", help="replace existing A/AAAA/CNAME records for the two names")
    sub.add_parser("status")
    a = ap.parse_args()
    cfg = settings()
    a.acct = account_id(a.account)
    try:
        return (cmd_create if a.cmd == "create" else cmd_status)(a, cfg) or 0
    except CFError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
