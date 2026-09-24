#!/usr/bin/env python3
"""Find, price, and buy a domain through Cloudflare Registrar's API.

    cf-domain.py search "coffee shop portland" [--tld com,dev]   ideas (cached, not authoritative)
    cf-domain.py check  mysite.com mysite.dev                  live availability + price
    cf-domain.py register mysite.com [--years 1]               BUY IT (asks you to confirm)
    cf-domain.py status mysite.com                             what you own

This is the same Registrar API the Cloudflare MCP server exposes, so an agent
can do all of this in conversation (see .claude/skills/merovingian). The script
is the no-agent path.

Money rules, enforced here and not just written down:
  * register re-checks price and availability immediately before buying
  * it shows the price and makes you TYPE the domain name to confirm
  * it refuses outright without a terminal; no flag skips the confirmation
  * premium domains are refused
  * auto-renew is ON, so the domain can't lapse and get sniped; turn it off in
    the dashboard if you prefer
Registrations are billed to the account's default payment method and are
NON-REFUNDABLE. Set up billing, a default registrant contact, and accept the
registration agreement in the dashboard first (PLAYBOOK.md, Phase 3).
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cfapi import CFError, account_id, call  # noqa: E402

POLL_SECONDS = float(os.environ.get("CF_POLL_SECONDS", "5"))


def check(acct, domains):
    _, p = call("POST", f"/accounts/{acct}/registrar/domain-check", {"domains": domains})
    return p["result"]["domains"]


def fmt_row(d):
    if d.get("registrable"):
        pr = d.get("pricing", {})
        return f"  AVAILABLE  {d['name']:<32} {pr.get('registration_cost', '?')} {pr.get('currency', '')}/yr, renews at {pr.get('renewal_cost', '?')}"
    return f"  no         {d['name']:<32} {d.get('reason', 'unavailable')}"


def cmd_search(a):
    q = {"q": a.query, "limit": a.limit}
    if a.tld:
        q["extensions"] = a.tld
    _, p = call("GET", f"/accounts/{a.acct}/registrar/domain-search", query=q)
    res = p["result"]
    items = res.get("domains", res) if isinstance(res, dict) else res
    print("Ideas (search is cached; run `check` before you decide):")
    for d in items:
        print(fmt_row(d) if isinstance(d, dict) else f"  {d}")


def cmd_check(a):
    for d in check(a.acct, a.domains):
        print(fmt_row(d))


def cmd_status(a):
    _, p = call("GET", f"/accounts/{a.acct}/registrar/registrations/{a.domain}")
    r = p["result"]
    print(f"{r.get('domain_name')}: {r.get('status')}, expires {r.get('expires_at')}, "
          f"auto_renew={r.get('auto_renew')}, privacy={r.get('privacy_mode')}, locked={r.get('locked')}")


def cmd_register(a):
    domain = a.domain.strip().lower()
    if not sys.stdin.isatty():
        sys.exit("ERROR: refusing to buy a domain without a terminal to confirm at. Run it yourself.")
    rows = check(a.acct, [domain])
    if not rows:
        sys.exit(f"ERROR: Cloudflare returned nothing for '{domain}'. Is it a full name like mysite.com?")
    d = rows[0]
    if not d.get("registrable"):
        sys.exit(f"ERROR: {domain} is not registrable: {d.get('reason', 'unavailable')}")
    if d.get("tier") != "standard":
        sys.exit(f"ERROR: {domain} is tier '{d.get('tier')}'. This script only buys standard-priced domains.")
    pr = d.get("pricing", {})
    total = float(pr.get("registration_cost", "0")) * a.years
    print(f"\n  Domain     {domain}")
    print(f"  Price      {pr.get('registration_cost')} {pr.get('currency')}/yr x {a.years} yr = {total:.2f} {pr.get('currency')}")
    print(f"  Renews at  {pr.get('renewal_cost')} {pr.get('currency')}/yr (auto-renew ON)")
    print("  Charged to your Cloudflare account's default payment method. NON-REFUNDABLE.\n")
    typed = input(f"Type the domain name to buy it, anything else cancels: ").strip().lower()
    if typed != domain:
        sys.exit("Cancelled. Nothing was bought.")

    body = {"domain_name": domain, "years": a.years, "auto_renew": True, "privacy_mode": "redaction"}
    status, p = call("POST", f"/accounts/{a.acct}/registrar/registrations", body)
    r = p["result"]
    print(f"Submitted (HTTP {status}).")
    deadline = time.time() + 300
    while not r.get("completed"):
        state = r.get("state")
        if state in ("action_required", "blocked"):
            print(f"Registration is '{state}'. Open the dashboard (Domain Registration) to finish it.")
            print(f"Detail: {r.get('context', {})}")
            return 1
        if time.time() > deadline:
            print(f"Still '{state}' after 5 minutes. Check later with: cf-domain.py status {domain}")
            return 1
        time.sleep(POLL_SECONDS)
        _, p = call("GET", f"/accounts/{a.acct}/registrar/registrations/{domain}/registration-status")
        r = p["result"]
    if r.get("state") != "succeeded":
        err = r.get("error") or {}
        sys.exit(f"ERROR: registration {r.get('state')}: {err.get('code')}: {err.get('message')}")

    a.domain = domain
    cmd_status(a)
    print("\nDone. Two things only you can do, today:")
    print("  1. Click the verification link Cloudflare emails the registrant address.")
    print("     Unverified, ICANN suspends the domain within ~15 days.")
    print("  2. Next: scripts/local/cf-tunnel.py create")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--account", help="Cloudflare account ID (default: CF_ACCOUNT_ID in playbook.env)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search"); s.add_argument("query"); s.add_argument("--limit", type=int, default=20)
    s.add_argument("--tld", type=lambda v: [x.strip().lstrip(".") for x in v.split(",") if x.strip()])
    c = sub.add_parser("check"); c.add_argument("domains", nargs="+")
    r = sub.add_parser("register"); r.add_argument("domain"); r.add_argument("--years", type=int, default=1, choices=range(1, 11))
    st = sub.add_parser("status"); st.add_argument("domain")
    a = ap.parse_args()
    a.acct = account_id(a.account)
    try:
        return {"search": cmd_search, "check": cmd_check, "register": cmd_register, "status": cmd_status}[a.cmd](a) or 0
    except CFError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
