# homelab-website-playbook

**Your website, on your domain, served from a computer in your house.** No hosting bill,
no open ports on your router, no server you have to babysit.

This is the complete playbook, with a script for every step and a crew of Claude Code agents
that can walk you through it:

- a spare computer becomes a **hardened, headless Linux server** (key-only SSH, firewall,
  fail2ban, kernel hardening) that **patches and reboots itself** and messages your phone
- you **buy a domain** at cost from Cloudflare Registrar, from the terminal or by asking Claude
- you **design a site** from four themes, or build your own from real design systems on
  [Refero Styles](https://styles.refero.design)
- **nginx** serves it on the server's loopback, and a **Cloudflare Tunnel** carries it to the
  internet. Visitors never learn your home IP, and nothing listens for them at your house.
- **one command deploys**, rolls back to the last running version by itself if the new one
  is broken, and proves the live site is the version you just shipped

**Start here: [PLAYBOOK.md](PLAYBOOK.md).**

## How it fits together

```
  laptop ── git push ──▶ GitHub ◀── git pull ── server: nginx on 127.0.0.1
                                                          ▲
                                               cloudflared │ (dials OUT)
                                                          ▼
                                   visitors ──HTTPS──▶ Cloudflare ──tunnel──▶ your site
```

## The crew (Claude Code agents)

Open this folder in [Claude Code](https://claude.com/claude-code) and say **"set me up"**.

| Agent | Does |
|---|---|
| `morpheus` | runs the playbook with you, phase by phase |
| `tank` | builds and hardens the server, sets up automatic updates |
| `merovingian` | finds, prices and buys your domain (you type the exact name to buy; every Cloudflare call it makes asks you first) |
| `trainman` | the tunnel and DNS; reads Cloudflare's error pages for you |
| `link` | builds and designs the site, including themes from Refero |
| `keeper` | deploys, verifies, rolls back |
| `sentinel` | read-only health and security audit |

Every agent ends its work with a check that can fail, and shows you the output. "Done"
means verified, not "the script finished".

## What's in the box

```
PLAYBOOK.md                 the walkthrough, phases 0 to 8
playbook.env.example        every setting, explained
scripts/server/             00-bootstrap ... 80-tunnel, audit.sh    (run on the server)
scripts/local/              cf-domain.py, cf-tunnel.py, new-site.sh, deploy.sh, rollback.sh, refero-css.py
scripts/verify-site.sh      proves a site is really up: status, negative control, marker, headers
site-starter/               Astro site + nginx + Docker, with a build-time quality gate
themes/                     midnight, parchment, moss, velvet (+ how to make your own)
templates/                  sshd, fail2ban, sysctl, update timers, cloudflared
.claude/skills/             the seven agents
docs/TROUBLESHOOTING.md     every silent failure we know about
tests/                      what CI runs on every push
```

## Requirements

- A 64-bit computer for the server, 4 GB RAM or more, wired network preferred.
  Ubuntu Server 24.04 LTS recommended, Debian 13 equally tested. Fedora and Rocky/Alma
  are supported by the scripts but not yet covered by CI.
- A laptop with git, ssh, python3 and Node.js 22+ (macOS or Linux).
- A Cloudflare account with a payment method for the domain (about $10/year for a .com).

## Tested

CI runs on every push:
- **shellcheck** on every script.
- **Server configs**, validated by the real daemons (`sshd -T`, `fail2ban-client -t`,
  `apt-config`, `unattended-upgrade`) inside Ubuntu 24.04 and Debian 13. Each check comes
  with a deliberately broken config that has to fail.
- **The server scripts run for real** in both distros (bootstrap, SSH, firewall, fail2ban,
  kernel, auto-updates, with systemd stubbed), then the audit. Docker, site and tunnel
  phases are covered by the site test below and by each phase's own live check.
- **The Cloudflare scripts, against a mock API.** Tokens are never printed, DNS is
  proxied, reruns change nothing, and a purchase is refused without a typed confirmation.
- **The starter site, in every theme.** Built in Docker, served, and verified with
  headers, build id and a negative control.
- **WCAG contrast** for every theme.
- **gitleaks** on the full history.

What CI can't test: your hardware, your router, and the real Cloudflare edge. Every
phase in the playbook ends with the check that covers that on your own setup.

## License

MIT. See [LICENSE](LICENSE). Themes credit the Refero Styles entries they studied;
Refero's content belongs to Refero and the companies it catalogs.
