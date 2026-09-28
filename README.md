# homelab-website-playbook

**Your website, on your domain, served from a computer in your house.** No hosting bill,
no open ports on your router, no server you have to babysit.

This is the complete playbook, with a script for every step and a crew of Claude Code agents
that can walk you through it:

- a spare computer becomes a **hardened, headless Linux server** (key-only SSH, firewall,
  fail2ban, kernel hardening) that **patches itself, watches itself**, and messages your phone
- you **buy a domain** at cost from Cloudflare Registrar, from the terminal or by asking Claude
- you **design a site** from four themes, or build your own from real design systems on
  [Refero Styles](https://styles.refero.design), then **add pages and blog posts with one
  command** each
- **nginx** serves it on the server's loopback, and a **Cloudflare Tunnel** carries it to the
  internet. Visitors never learn your home IP, and nothing listens for them at your house.
- **one command deploys**, rolls back to the last good version by itself if the new one
  is broken, and proves the live site is the version you just shipped. Or push to GitHub
  and let the server deploy it.

**Start here: [PLAYBOOK.md](PLAYBOOK.md).**

## One command: `./playbook`

```
$ ./playbook
  0 laptop done  tools ok, node 22.12.0, playbook.env valid
  1 server done  friend@homelab (Ubuntu 24.04.1 LTS)
  2 harden done  all six steps; audit 3h ago: 0 fail, 1 warn
  3 domain done  mapleandpine.com: active, auto-renew on, expires 2027-09-23
  4 site   done  ~/sites/mysite -> https://github.com/friend/mysite.git
  5 serve  done  127.0.0.1:8080 healthy, build 3f2a9c1d0e4b
  6 live   FAIL  https://mapleandpine.com: home page answered 502; connector ready: yes
  7 ship   skip  needs a live site and a local site
  8 watch  FAIL  watch 4m ago: mysite: public: home page answered 502
next: ./playbook why   (phase 6, trainman)
```

Every row is measured live, not remembered. `./playbook why` reads the log of the last
run, matches it against every failure this playbook knows, and prints what it means and
the one fix. `./playbook server <step>` runs each server phase from your laptop, so you
never type ssh, scp or cd. `./playbook help` lists everything.

## Built so your AI doesn't have to think hard

The expensive part of an AI helper is reasoning: reading long documents to find where
you are, and reading long logs to find what broke. This playbook moves that work into
scripts, so a Claude Code session mostly runs one command and relays one line:

- **Where am I?** `./playbook status`: one ssh round trip, one line per phase.
- **What broke?** `./playbook why`: a lookup table of known failures, each with its fix.
- **What does this phase involve?** `./playbook guide 6` prints one phase, not the book.
- **Quiet by default.** apt, Docker and npm output goes to log files; each step prints
  one line, or the last lines of the log when it fails.
- **Structure from scripts, prose from you.** `./playbook site post "Title"` makes the
  post; the model only writes the words. The site's build checks SEO, accessibility and
  the security policy for free, so nobody has to review for them.
- **A status line** in Claude Code shows the phase, the next step, context used and cost.

## The crew (Claude Code agents)

Open this folder in [Claude Code](https://claude.com/claude-code) and say **"set me up"**.

| Agent | Does |
|---|---|
| `morpheus` | runs the playbook with you, phase by phase |
| `tank` | builds and hardens the server, updates, monitoring |
| `merovingian` | finds, prices and buys your domain (you type the exact name, and a code shown at that moment) |
| `trainman` | the tunnel, DNS and HTTPS; reads Cloudflare's error pages for you |
| `link` | builds and designs the site, pages and posts, themes from Refero |
| `keeper` | deploys, verifies, rolls back, auto-deploy |
| `sentinel` | read-only health and security check |

Every agent ends its work with a check that can fail, and shows you the output. "Done"
means verified, not "the script finished". Steps that need your password or your
money refuse to run inside an agent: it hands you the exact line to type.

## What's in the box

```
playbook                    the front door: status, why, guide, server/site/domain steps, deploy
PLAYBOOK.md                 the walkthrough, phases 0 to 8
playbook.env.example        every setting, explained
scripts/server/             00-bootstrap ... 90-watch, audit, site-deploy, probe (run on the server)
scripts/local/              status, diagnose (why), deploy, rollback, new-site, cf-domain, cf-tunnel, refero-css
scripts/verify-site.sh      proves a site is really up: status, content type, negative control, marker, headers
site-starter/               Astro site + blog + nginx + Docker, build-time quality gates, GitHub workflows
themes/                     midnight, parchment, moss, velvet (+ how to make your own)
templates/                  sshd, fail2ban, sysctl, update and watch timers, cloudflared
.claude/                    the seven agents, permission rules, the status line
docs/TROUBLESHOOTING.md     every failure we know about, one section each
tests/                      what CI runs on every push
```

## Requirements

- A 64-bit computer for the server, 4 GB RAM or more, wired network preferred.
  Ubuntu Server 24.04 LTS recommended, Debian 13 equally tested. Fedora and Rocky/Alma
  are supported by the scripts but not yet covered by CI.
- A laptop with git, ssh, python3 and Node.js 22.12+ (macOS or Linux).
- A Cloudflare account with a payment method for the domain (about $10/year for a .com).

## Tested

CI runs on every push:
- **shellcheck** on every script, **actionlint** on this repo's workflows and the ones
  every site gets, **gitleaks** on the full history.
- **Server configs**, validated by the real daemons (`sshd -T`, `fail2ban-client -t`,
  `apt-config`, `unattended-upgrade`) inside Ubuntu 24.04 and Debian 13, each with a
  deliberately broken config that has to fail. "Security updates only" is checked in
  unattended-upgrades' own list of allowed origins.
- **The server scripts run for real** in both distros (bootstrap, SSH, firewall, fail2ban,
  kernel, automatic updates, the watch installer), with a systemd stub that remembers
  what was enabled, then the audit, including cases it must FAIL. The firewall's lockout
  guard is proven against a real sshd and real sessions, run through sudo.
- **The watch** through every state: one blip (silence), down (one message), still down
  (silence), back up, after a reboot, and the heartbeat.
- **Deploys, for real:** Docker builds from a local git remote, including a build that
  fails, a version that starts unhealthy and is rolled back automatically, a rollback
  that reuses the previous image, and auto-deploy skipping a known-bad commit.
- **The starter site, in every theme,** built in Docker, served, and verified: headers,
  build id, a negative control, the blog and feeds, relative redirects, caching.
- **Its build checks** (SEO, accessibility, security policy, links), each rule with a
  fixture that must fail it, and the content scripts.
- **The Cloudflare scripts, against a mock API.** Tokens are never printed, DNS is
  proxied, reruns change nothing, and a purchase needs the typed name and code.
- **`status`, `why`, `verify-site` and the permission rules**, each with a control:
  a clean run matches no failure, a server that answers everything fails, and the old
  permission rules (which matched nothing) fail the settings check.

What CI can't test: your hardware, your router, and the real Cloudflare edge. Every
phase in the playbook ends with the check that covers that on your own setup.

## License

MIT. See [LICENSE](LICENSE). Themes credit the Refero Styles entries they studied;
Refero's content belongs to Refero and the companies it catalogs.
