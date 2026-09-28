#!/usr/bin/env python3
"""Explain a failure: match a log against every failure this playbook knows.

    ./playbook why                  the most recent run
    ./playbook why <logfile>        a specific log
    ./playbook why -                read the log from stdin
    ./playbook why --list           every known failure, one line each

Prints, for each match (newest first, at most three): what it means, the one
fix, the agent that owns it, and the section of docs/TROUBLESHOOTING.md with
the detail. Nothing matched? It prints the last 25 lines and says so, rather
than guessing.

This is a lookup table, on purpose. Debugging by pattern match costs nothing;
debugging by reasoning through a 2000-line build log costs a lot, and is the
same answer every time for the failures below. When a new failure turns up,
add it here with an `example` line: tests/test_diagnose.py proves every
example matches its own entry, and that every `doc` anchor exists.

Exit 0 when something matched, 3 when nothing did.
"""
import glob
import os
import re
import sys

# id, pattern (case-insensitive), what it means, the fix, owner, doc anchor, a real example line
CATALOG = [
    ("needs-terminal", r"has to run in YOUR terminal|sudo: a (terminal|password) is required",
     "This step asks for your server password, so it can't run inside an agent.",
     "Paste the line it printed (it starts with `./playbook`) into your own terminal, then come back.", "morpheus", "steps-that-need-your-terminal",
     "This step asks for your server password (sudo), so it has to run in YOUR terminal:"),
    ("config", r"playbook\.env: |set these in playbook\.env|no config at .*playbook\.env",
     "playbook.env is missing a value or has one in the wrong shape.",
     "Fix the line it names in playbook.env (every line is explained in playbook.env.example), then ./playbook status.", "morpheus", "playbookenv",
     "FAIL playbook.env: SITE_NAME 'My Site': lowercase letters, digits and dashes only"),
    ("ssh-key-refused", r"Permission denied \(publickey",
     "The server answered but refused your key: it doesn't have your laptop's public key for ADMIN_USER, or ADMIN_USER is wrong.",
     "./playbook server key   (asks for the server password once). Check ADMIN_USER matches the user you created at install.", "tank", "ssh-refuses-your-key",
     "friend@192.168.1.50: Permission denied (publickey)."),
    ("ssh-hostkey-changed", r"REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed",
     "The server's identity changed since you last connected. Expected if you reinstalled it; otherwise something is impersonating it.",
     "Only if you reinstalled the server: ssh-keygen -R <SERVER_HOST>, then retry. If you didn't, stop and ask someone.", "tank", "the-servers-identity-changed",
     "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @"),
    ("ssh-unreachable", r"(connect to host .* port \d+: (Operation timed out|Connection timed out|No route to host|Host is down))|ssh: connect to host .*: Network is unreachable",
     "Nothing answered at SERVER_HOST: the server is off, its address changed, or fail2ban banned your laptop.",
     "Is it on? Check the address in your router (a DHCP reservation keeps it fixed). If you've been failing logins, see the ban section.", "tank", "the-server-doesnt-answer",
     "ssh: connect to host 192.168.1.50 port 22: Operation timed out"),
    ("ssh-refused", r"connect to host .* port \d+: Connection refused",
     "The server is up but nothing listens on that SSH port: wrong SSH_PORT, or sshd is stopped.",
     "Check SSH_PORT in playbook.env matches the server. At the server's keyboard: sudo systemctl status ssh", "tank", "the-server-doesnt-answer",
     "ssh: connect to host 192.168.1.50 port 2222: Connection refused"),
    ("ssh-resolve", r"Could not resolve hostname",
     "SERVER_HOST isn't a name your laptop knows.",
     "Use the server's IP address, or add a Host entry for it in ~/.ssh/config (PLAYBOOK.md Phase 1).", "tank", "the-server-doesnt-answer",
     "ssh: Could not resolve hostname homelab: nodename nor servname provided, or not known"),
    ("lan-cidr", r"OUTSIDE LAN_CIDR",
     "LAN_CIDR doesn't include the address you're connected from; applying it would lock you out, so nothing was changed.",
     "Fix LAN_CIDR in playbook.env (or leave it empty), then ./playbook server harden.", "tank", "locked-out-of-ssh",
     "ERROR: an SSH session is open from 10.0.0.5, which is OUTSIDE LAN_CIDR=192.168.1.0/24."),
    ("sshd-config", r"sshd rejected the config|another config file overrides ours|does not Include sshd_config\.d",
     "The SSH hardening didn't apply: sshd rejected it, or another file wins over it.",
     "Nothing was changed. Run: sudo sshd -T | grep -iE 'password|root' on the server and see which file sets it.", "tank", "ssh-changes-didnt-apply",
     "ERROR: another config file overrides ours; see 'sshd -T' and /etc/ssh/sshd_config.d/"),
    ("apt-lock", r"Could not get lock /var/lib/dpkg/lock|dpkg frontend lock|is another process using it",
     "The server is installing updates in the background (common right after first boot).",
     "Wait five minutes and run the same step again. It's safe to re-run.", "tank", "the-package-manager-is-busy",
     "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 1234 (unattended-upgr)"),
    ("no-internet-server", r"Temporary failure resolving|Could not resolve host: (download\.docker\.com|deb\.debian\.org|archive\.ubuntu\.com)",
     "The server can't reach the internet (no DNS or no route).",
     "Check its network cable and router. On the server: ping -c1 1.1.1.1 and getent hosts github.com", "tank", "the-server-has-no-internet",
     "Temporary failure resolving 'archive.ubuntu.com'"),
    ("docker-snap", r"docker snap|/snap/bin/docker|snap\.docker",
     "Docker was installed as a snap during Ubuntu's setup. The snap ignores this playbook's Docker settings and can't read /srv.",
     "sudo snap remove --purge docker, then ./playbook server harden again.", "tank", "docker-came-from-a-snap",
     "ERROR: Docker is installed as a snap (/snap/bin/docker)."),
    ("docker-group", r"permission denied while trying to connect to the docker|can't talk to docker",
     "Your user was just added to the docker group, and that only applies to NEW logins.",
     "Run the step again: each `./playbook server` step is a fresh login.", "tank", "docker-permission-denied",
     "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock"),
    ("port-in-use", r"port is already allocated|address already in use|bind: address already in use",
     "Another program on the server already uses that port.",
     "Pick another SITE_PORT (or TUNNEL_METRICS_PORT) in playbook.env, then run the step again.", "tank", "a-port-is-already-in-use",
     "Error response from daemon: driver failed programming external connectivity: Bind for 127.0.0.1:8080 failed: port is already allocated"),
    ("disk-full", r"no space left on device",
     "The server's disk is full.",
     "On the server: docker system prune -af (removes unused images), then df -h /.", "tank", "the-disk-is-full",
     "write /var/lib/docker/tmp/x: no space left on device"),
    ("node-old", r"Node\.js v?\d+[\d.]* is not supported|Unsupported engine|requires Node|node \d+[\d.]*; Astro needs",
     "Your Node.js is older than Astro needs (22.12+).",
     "Install Node.js 22 LTS from https://nodejs.org, open a new terminal, then ./playbook doctor.", "link", "nodejs-is-too-old",
     "Node.js v20.19.6 is not supported by Astro!"),
    ("npm-resolve", r"npm (ERR!|error) (code )?ERESOLVE",
     "Two packages want different versions of the same dependency.",
     "Undo the package change that caused it (git checkout package.json package-lock.json), then add it again with a compatible version.", "link", "the-build-fails",
     "npm error code ERESOLVE"),
    ("inline-script", r"inline <script> would be blocked by the CSP",
     "A page has an inline <script>. It works in npm run dev, which has no security policy, and is blocked in production.",
     "Move the script into a file in src/scripts/ and import it, or delete it.", "link", "something-works-in-dev-but-not-live",
     "FAIL /index.html: inline <script> would be blocked by the CSP in production"),
    ("inline-handler", r"inline on[a-z]+= handler|javascript: URL on",
     "A page uses onclick= (or another on...= attribute) or a javascript: link. The security policy blocks both in production.",
     "Move the behavior into a script file in src/scripts/ that adds an event listener, and use a real link.", "link", "something-works-in-dev-but-not-live",
     "FAIL /index.html: inline onclick= handler on <button> would be blocked by the CSP in production"),
    ("csp-external", r"not allowed by the CSP|blocked by the CSP",
     "A page loads something from another site that the security policy doesn't allow.",
     "Host the file yourself (public/ or src/assets/), or add its host to the Content-Security-Policy line in nginx.conf.", "link", "something-works-in-dev-but-not-live",
     "FAIL /index.html: stylesheet https://fonts.googleapis.com/css2 is blocked by the CSP (style-src in nginx.conf); add the host there or serve the file from this site"),
    ("broken-link", r"broken link ",
     "A page links to a file or page that isn't in the built site.",
     "Fix the link it names (a typo, or a file that moved), then ./playbook site check.", "link", "the-build-fails",
     "FAIL /about/index.html: broken link /img/team.jpg"),
    ("site-check", r"^\s*FAIL (/|missing |index\.html|rss\.xml|src/site\.json|dist/)|site checks failed",
     "The site's own checks failed: the lines starting with FAIL say exactly what.",
     "Fix each FAIL line, then ./playbook site check. Nothing ships until it passes.", "link", "the-build-fails",
     "FAIL /blog/index.html: not exactly one <h1> (found 2)"),
    ("build-failed", r"FAIL the build of [0-9a-f]+ failed",
     "The server's build of your commit failed. The version that was live is still live, untouched.",
     "Run ./playbook site check on your laptop: it runs the same checks and shows why. Fix, commit, deploy.", "keeper", "a-deploy-failed",
     "FAIL the build of 3f2a9c1d0e4b failed (its own checks run inside it). 9c1b2d3e4f5a is still live, untouched."),
    ("unhealthy-rollback", r"started but isn't healthy|was unhealthy, so the server put the previous one back",
     "The new version built but didn't answer correctly, so the previous version was put back automatically. The site is up.",
     "Check nginx.conf and anything that changed how pages are served. ./playbook site dev to try it locally.", "keeper", "a-deploy-failed",
     "FAIL 3f2a9c1d0e4b started but isn't healthy. Rolling back to 9c1b2d3e4f5a."),
    ("site-down", r"THE SITE IS DOWN|SITE DOWN",
     "A deploy failed AND putting the old version back failed. The site is down.",
     "./playbook status, then ./playbook server site to rebuild what's on main. If that fails too, ./playbook why on its log.", "keeper", "a-deploy-failed",
     "FAIL the rollback to 9c1b2d3e4f5a is ALSO unhealthy. THE SITE IS DOWN."),
    ("dirty-tree", r"uncommitted changes",
     "You have edits that aren't committed. A deploy ships commits, not files.",
     "git add -A && git commit -m \"what changed\", then ./playbook deploy.", "keeper", "a-deploy-failed",
     "ERROR: uncommitted changes. Commit or stash them; a deploy ships commits, not files."),
    ("diverged", r"have both changed|has commits GitHub doesn't|server checkout has diverged",
     "Two copies of main changed separately (your laptop and GitHub, or someone edited on the server).",
     "On the laptop: git pull --rebase, then deploy. Never force-push, never edit files on the server.", "keeper", "a-deploy-failed",
     "ERROR: your main and GitHub's have both changed. Run: git pull --rebase   (then deploy again)"),
    ("push-race", r"but the laptop pushed",
     "GitHub's main moved between your push and the server's pull (another push landed).",
     "./playbook deploy again.", "keeper", "a-deploy-failed",
     "FAIL origin/main is 1a2b3c4d5e6f, but the laptop pushed 3f2a9c1d0e4b. Push again, then deploy."),
    ("private-repo", r"could not read Username|Repository not found|without a deploy key|couldn't clone",
     "The server can't read your site's repo: it's private, or SITE_REPO is wrong.",
     "Make the repo public (it's a website), or give the server a deploy key.", "tank", "private-site-repo",
     "fatal: could not read Username for 'https://github.com': No such device or address"),
    ("stale-live", r"the live site is not serving|live site is not serving",
     "The server has the new version, but the internet still sees the old one: something between is caching HTML.",
     "curl -s https://<domain>/ | grep name=\"build\" to see what's served, then look for a Cache Rule in Cloudflare.", "keeper", "the-site-looks-old",
     "ERROR: the live site is not serving 3f2a9c1d0e4b."),
    ("tunnel-token", r"Provided Tunnel token is not valid|Unauthorized: Failed to get tunnel|Invalid tunnel secret|isn't ready after 60s",
     "The tunnel connector can't authenticate: its token is wrong, or the tunnel was deleted or recreated.",
     "./playbook server tunnel   (fetches a fresh token and installs it; nothing to copy by hand).", "trainman", "error-1033-the-tunnel-isnt-connected",
     "Provided Tunnel token is not valid."),
    ("tunnel-1033", r"Error 1033|error code: 1033|home page answered 530",
     "Cloudflare has no running connector for your tunnel.",
     "./playbook status (is the connector ready?), then ./playbook server tunnel.", "trainman", "error-1033-the-tunnel-isnt-connected",
     "  FAIL home page answered 530"),
    ("tunnel-1014", r"Error 1014|error code: 1014|lives in a different Cloudflare account",
     "Your domain and your tunnel are in different Cloudflare accounts.",
     "Use one account for both: set CF_ACCOUNT_ID to the account that holds the domain, then ./playbook server tunnel.", "trainman", "error-1014",
     "ERROR: example.com lives in a different Cloudflare account (Friend's Account)."),
    ("origin-502", r"home page answered 502",
     "The tunnel works, but the site behind it isn't answering on the server.",
     "./playbook server site (rebuilds and starts it on 127.0.0.1).", "tank", "cloudflare-shows-502",
     "  FAIL home page answered 502"),
    ("ingress-404", r"home page answered 404",
     "The request reached your tunnel, but its routing has no rule for this hostname, so the catch-all answered 404.",
     "./playbook server tunnel (re-applies the routing for your domain and www).", "trainman", "the-home-page-answers-404",
     "  FAIL home page answered 404"),
    ("challenge", r"Cloudflare challenge|INDETERMINATE",
     "Cloudflare answered with a bot check instead of your page, so the check can't tell either way.",
     "Usually harmless (automated checks get challenged). If visitors see it too: Security > Settings in the dashboard, lower the security level or turn off Bot Fight Mode.", "trainman", "a-cloudflare-challenge-page",
     "INDETERMINATE https://example.com: a Cloudflare challenge answered instead of the site"),
    ("no-dns", r"no answer at all \(DNS, TLS or connection failure\)",
     "Your domain doesn't lead anywhere yet: no DNS record, or it's too new to have spread.",
     "./playbook tunnel status (are both DNS records there?). New records take a few minutes.", "trainman", "the-domain-doesnt-resolve",
     "  FAIL no answer at all (DNS, TLS or connection failure)"),
    ("headers-missing", r"header (content-security-policy|x-content-type-options|referrer-policy|permissions-policy) missing",
     "The page arrived without its security headers: an add_header in a location block, or it isn't your nginx answering.",
     "Keep every add_header at server level in nginx.conf. If the page is a Cloudflare error page, fix that first.", "link", "the-security-headers-disappeared",
     "  FAIL header content-security-policy missing (an add_header inside a location block drops every inherited one)"),
    ("dns-conflict", r"already has (A|AAAA|CNAME)|is a CNAME to .* --replace-dns",
     "Your domain already has DNS records (often a parking page from the registrar).",
     "Look at the record it names. If it's parking or a placeholder: ./playbook tunnel create --replace-dns", "trainman", "the-domain-doesnt-resolve",
     "ERROR: example.com already has A 192.0.2.1. A name can't have both those and a CNAME."),
    ("no-zone", r"no Cloudflare zone for",
     "Cloudflare doesn't manage DNS for this domain yet.",
     "Registered at Cloudflare? It appears within minutes. Registered elsewhere? Add it as a site in the dashboard and switch its nameservers.", "merovingian", "the-domain-doesnt-resolve",
     "ERROR: no Cloudflare zone for example.com."),
    ("cf-token", r"no Cloudflare API token|token invalid, expired, or missing a permission|HTTP 403: 10000|9109",
     "The Cloudflare API token is missing, expired, or lacks a permission this step needs.",
     "Recreate it with the permissions in PLAYBOOK.md Phase 3, save it with the command shown there, then retry.", "merovingian", "the-cloudflare-token",
     "  (token invalid, expired, or missing a permission; see PLAYBOOK.md Phase 3)"),
    ("cf-account", r"set CF_ACCOUNT_ID",
     "CF_ACCOUNT_ID isn't set.",
     "Copy the Account ID from the right sidebar of any Cloudflare dashboard page into playbook.env.", "merovingian", "the-cloudflare-token",
     "ERROR: set CF_ACCOUNT_ID in playbook.env (dashboard: the Account ID in the right sidebar)"),
    ("domain-unavailable", r"is not registrable|tier 'premium'|no usable price",
     "That domain can't be bought here: taken, premium, or no price came back.",
     "Try another name: ./playbook domain check name1.com name2.com", "merovingian", "buying-a-domain",
     "ERROR: coffee.xyz is tier 'premium'. This script only buys standard-priced domains."),
    ("registration-held", r"Registration is '(action_required|blocked)'",
     "The registration needs something only the dashboard can do (billing, contact, agreement).",
     "Cloudflare dashboard > Domain Registration: finish what it asks. Don't retry the purchase.", "merovingian", "buying-a-domain",
     "Registration is 'action_required'. Open the dashboard (Domain Registration) to finish it."),
    ("fail2ban-ban", r"Currently banned:\s*[1-9]|banned your laptop",
     "fail2ban banned an address, possibly your laptop's.",
     "From the server's keyboard or another device on your network: sudo fail2ban-client set sshd unbanip <your laptop's IP>", "tank", "everything-fails-from-your-laptop",
     "   |- Currently banned:	1"),
    ("updates-stale", r"security updates haven't (succeeded|run)",
     "Automatic security updates have stopped working.",
     "On the server: sudo unattended-upgrade -d | tail -40 shows why. Usually a broken third-party repo.", "tank", "automatic-updates-stopped",
     "  FAIL security updates haven't succeeded since 2026-09-01 (22 days)"),
]


def find_default_log():
    d = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "homelab-playbook", "logs")
    logs = sorted(glob.glob(os.path.join(d, "*.log")), key=os.path.getmtime)
    return logs[-1] if logs else None


def diagnose(text):
    """Return (line, entry, the matching line) for every catalog entry that
    matches: the latest line in the log first, and on the same line the entry
    listed first in CATALOG (specific entries come before generic ones)."""
    lines = text.splitlines()
    found = []
    for idx, entry in enumerate(CATALOG):
        last = -1
        for m in re.finditer(entry[1], text, re.I | re.M):
            last = text.count("\n", 0, m.start())
        if last >= 0:
            found.append((last, idx, entry, lines[last] if last < len(lines) else ""))
    found.sort(key=lambda f: (-f[0], f[1]))
    return [(f[0], f[2], f[3]) for f in found]


def main(argv):
    if argv[:1] == ["--list"]:
        for e in CATALOG:
            print(f"  {e[0]:<20} {e[2]}")
        return 0
    if argv[:1] == ["-"]:
        path, text = "stdin", sys.stdin.read()
    else:
        path = argv[0] if argv else find_default_log()
        if not path:
            print("Nothing logged yet (every `./playbook` step logs its run). Or: ./playbook why <logfile>")
            return 3
        try:
            with open(path, errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            print(f"can't read {path}: {e}")
            return 3
    print(f"reading {path}")
    hits = diagnose(text)
    if not hits:
        print("\nNo known failure in this log. The last 25 lines:\n")
        for line in text.rstrip().splitlines()[-25:]:
            print("  " + line)
        print("\nIf this is a new kind of failure, it belongs in scripts/local/diagnose.py.")
        return 3
    seen = set()
    n = 0
    for _, e, line in hits:
        if e[0] in seen or n == 3:
            continue
        seen.add(e[0])
        n += 1
        print(f"\n{n}. {e[2]}   [{e[4]}]")
        print(f"   seen: {line.strip()[:160]}")
        print(f"   fix:  {e[3]}")
        print(f"   more: docs/TROUBLESHOOTING.md#{e[5]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
