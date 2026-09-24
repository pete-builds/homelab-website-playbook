# The Playbook

From a spare computer to your own website on your own domain, served from your house,
hardened, patching itself, with nothing exposed to the internet.

Budget an afternoon for the first pass. Every phase ends with a check that proves it
worked. Don't move on until it passes.

```
 your laptop                     your server (at home)                    the internet
 ───────────                     ─────────────────────                    ────────────
 edit site ──git push──▶ GitHub ◀──git pull── /srv/sites/<site>
                                              nginx container
                                              127.0.0.1:8080 (loopback only)
                                                    ▲
                                                    │ plain HTTP, never leaves the box
                                              cloudflared container ──outbound──▶ Cloudflare edge ◀── visitors
                                                                       tunnel      HTTPS, your domain
 firewall: deny ALL inbound except SSH from your LAN. Router: forward nothing.
```

With Claude Code, open this folder and say **"set me up"**: the `morpheus` agent runs
this document with you, phase by phase. Without it, follow along below; every step is
a script you run.

---

## Phase 0: Your laptop

You need `git`, `ssh`, `python3`, `curl`, and Node.js 22 or newer.

```sh
git clone https://github.com/pete-builds/homelab-website-playbook
cd homelab-website-playbook
cp playbook.env.example playbook.env      # then fill it in; every line is explained
./scripts/local/preflight.sh
```

No SSH key yet? `ssh-keygen -t ed25519` and accept the defaults.

**Check:** `preflight.sh` shows no `FAIL` lines.

## Phase 1: The server

**Hardware.** Any 64-bit machine with 4 GB of RAM or more: an old laptop, a used mini PC,
a Raspberry Pi 4/5. Wired Ethernet beats Wi-Fi. It will run 24/7 on a few watts.

**Install** [Ubuntu Server 24.04 LTS](https://ubuntu.com/download/server). Debian 13 is
tested just as thoroughly. Fedora and Rocky/Alma are supported by the scripts (they enable
EPEL for fail2ban) but aren't tested in CI yet. During the install:
- create your user. That name goes in `ADMIN_USER`.
- tick **Install OpenSSH server**, and **Import SSH key** from GitHub if offered.
- no desktop. Headless means no monitor needed after this.

**In your router**, give the server a fixed address (a "DHCP reservation"). That address
goes in `SERVER_HOST`. Nicer still, add to `~/.ssh/config` on your laptop:

```
Host homelab
    HostName 192.168.1.50
    User admin
    Port 22
```

and set `SERVER_HOST=homelab`. If you change `SSH_PORT` later, change `Port` here too.

**Get the playbook onto it:**

```sh
ssh homelab
sudo apt install -y git         # Fedora/RHEL: sudo dnf install -y git
git clone https://github.com/pete-builds/homelab-website-playbook ~/homelab-website-playbook
exit
scp playbook.env homelab:homelab-website-playbook/
```

**Bootstrap** (on the server):

```sh
cd ~/homelab-website-playbook
sudo ./scripts/server/00-bootstrap.sh
```

It installs base packages, sets the timezone, and makes sure your user has your key and
sudo. Safe to re-run.

**Check:** from the laptop, `ssh -t homelab 'sudo -v && echo ok'` asks for your password and prints `ok`.

## Phase 2: Harden it

All on the server, in order. Read what each prints.

```sh
sudo ./scripts/server/10-harden-ssh.sh     # key-only SSH, no root login
sudo ./scripts/server/20-firewall.sh       # deny everything inbound except SSH
sudo ./scripts/server/30-fail2ban.sh       # ban password-guessers
sudo ./scripts/server/40-kernel.sh         # network hardening
sudo ./scripts/server/50-docker.sh         # Docker, from Docker's signed repo
sudo ./scripts/server/60-auto-updates.sh     # asks for your notification URL, hidden
```

**10-harden-ssh has a safety net.** Run it in your own terminal (not through an agent).
Before it runs, open a *second* terminal. After it restarts SSH, log in from that second
terminal. If it works, type `yes` in the first. If you don't within 5 minutes, a timer
undoes the change, even if your first session dropped. It also refuses to run if your
user has no key, because turning passwords off then would lock you out.

**20-firewall and `LAN_CIDR`.** If you set `LAN_CIDR`, SSH is accepted only from that
network. The script checks the address you're connected from and refuses a value that
would lock you out. Not sure what your network is? Leave it empty.

**60-auto-updates** sets up the hands-off part:

| When | What |
|---|---|
| daily | security updates install automatically |
| daily at `REBOOT_TIME` | reboots **only if** an update needs it, and tells you first |
| Sundays 05:00 | rebuilds your site on a fresh nginx image, checks it's healthy, tells you if a newer cloudflared exists |
| after any reboot | "back up after boot" |

The script asks where those messages should go. [ntfy](https://ntfy.sh) is free: install
the app, subscribe to a long random topic name (anyone who guesses it can read it), and
paste `https://ntfy.sh/<topic>`. A Discord webhook URL works too.
Email doesn't: many ISPs block outbound mail, and it fails without a word.

**Check:**
```sh
sudo ./scripts/server/audit.sh        # on the server: no FAIL lines
                                      # from the laptop: ssh -t homelab 'sudo ~/homelab-website-playbook/scripts/server/audit.sh' 
```
and prove it from the laptop:
```sh
ssh -o PubkeyAuthentication=no homelab     # must say: Permission denied (publickey)
nc -zv -w 3 <server-ip> 80                 # must fail: nothing is listening
```

## Phase 3: Your domain

You'll buy it from **Cloudflare Registrar**: it charges exactly what the registry
charges (no markup, typically around $10/year for a .com), WHOIS privacy is free, and it
lives in the same account as the tunnel, which matters later.

**One-time account setup** in the [Cloudflare dashboard](https://dash.cloudflare.com):
1. Sign up, and verify your email.
2. **Billing**: add a payment method. Registration charges it automatically.
3. **Domain Registration**: set a default registrant contact and accept the Domain
   Registration Agreement. The API can't do these for you.
4. Copy your **Account ID** (right sidebar of any account page) into `CF_ACCOUNT_ID`.

**Pick a way to buy:**

**A. Ask Claude** (uses the Cloudflare MCP server this repo registers in `.mcp.json`).
In Claude Code, run `/mcp`, choose `cloudflare-api`, and log in in the browser window.
Then: *"find me a domain for a handmade furniture shop"*. The `merovingian` agent searches,
checks live prices, and when you're ready, asks you to **type the exact domain** before
buying anything.

**B. The script**, with an API token:
1. Dashboard: **My Profile > API Tokens > Create Token > Create Custom Token**.
2. Permissions:
   - Account: **Cloudflare Tunnel: Edit**
   - Zone: **DNS: Edit**
   - Zone: **Zone: Read**
   - To buy through the script as well, add the Registrar permission with write/edit
     access. Cloudflare's [Registrar API guide](https://developers.cloudflare.com/registrar/registrar-api/)
     calls it "Registrar write permissions".
3. Account Resources: your account. Zone Resources: all zones in the account.
4. Save it where only you can read it (it's shown once):
   ```sh
   mkdir -p ~/.config/homelab-playbook
   ( umask 077; pbpaste > ~/.config/homelab-playbook/cloudflare.token )   # macOS, after copying it
   # Linux: ( umask 077; cat > ~/.config/homelab-playbook/cloudflare.token ), paste, Enter, Ctrl-D
   ```
5. Shop and buy:
   ```sh
   ./scripts/local/cf-domain.py search "handmade furniture" --tld com,co,studio
   ./scripts/local/cf-domain.py check mapleandpine.com mapleandpine.co cloudflare.com
   ./scripts/local/cf-domain.py register mapleandpine.com
   ```
   Put a domain you know is taken (like `cloudflare.com`) in every `check`. If it ever
   says *available*, the check is broken; don't trust it.

Registrations are **non-refundable**. Auto-renew is switched on so it can't lapse.

**Right after buying:** click the verification link Cloudflare emails to your registrant
address. Unverified domains get suspended within about two weeks.

Put the domain in `DOMAIN`.

**Check:** `./scripts/local/cf-domain.py status <domain>` says `active`.

## Phase 4: Your site

```sh
./scripts/local/new-site.sh --theme parchment     # or midnight, moss, velvet
cd ~/sites/mysite                                  # whatever SITE_DIR is
npm install && npm run dev                         # http://localhost:4322
```

Edit `src/pages/index.astro`. Your title, description and `SITE_MARKER` sentence live in
`src/site.json`. Keep the marker on the home page: the live checks look for it.

**Themes** are described in [`themes/README.md`](themes/README.md), including how to make
your own from any design system on [Refero Styles](https://styles.refero.design)
with `scripts/local/refero-css.py`. Or ask the `link` agent: *"make it feel like Wise"*.

**Put it on GitHub** so the server can pull it:

```sh
gh repo create mysite --public --source . --push
```

and set `SITE_REPO` to its URL. Public is simplest: it's a website, it'll be public anyway.
For a private repo, see [Private site repo](docs/TROUBLESHOOTING.md#private-site-repo).

**Check:** `npm run build && npm run check` both succeed.

## Phase 5: Run it on the server

Copy your updated `playbook.env` over, then on the server:

```sh
scp playbook.env homelab:homelab-website-playbook/
ssh homelab
cd ~/homelab-website-playbook && ./scripts/server/70-site.sh
```

It clones your site, builds it in Docker (running the site's own checks inside the
build), and starts nginx on `127.0.0.1` only. Nobody else can reach it yet. That's the point.

**Check:** the script ends with `home 200, missing page 404`.

## Phase 6: Go live through the tunnel

On the laptop:

```sh
./scripts/local/cf-tunnel.py create
```

This creates the tunnel, routes `yourdomain` and `www.yourdomain` to your site, creates
the DNS records, and saves the tunnel's token to a private file. It prints the next
command, which ships that token to the server over SSH, without it ever appearing on
screen:

```sh
ssh homelab 'cd ~/homelab-website-playbook && ./scripts/server/80-tunnel.sh' < ~/.config/homelab-playbook/tunnel-mysite.token
```

The server starts the connector, waits until Cloudflare confirms it, then checks your
domain from the outside.

**Check:** it ends with `<domain> is live`. Open it on your phone, on mobile data.

## Phase 7: Everyday life

Edit, commit, then:

```sh
./scripts/local/deploy.sh
```

It refuses uncommitted work, runs your checks, pushes, rebuilds on the server, **rolls
back by itself** if the new version isn't healthy, and finally proves the live site is
serving the exact commit you just made. Changed your mind?

```sh
./scripts/local/rollback.sh
```

## Phase 8: Keep an eye on it

The server patches and reboots itself and messages you when it does. Once in a while
(or ask the `sentinel` agent: *"is everything ok?"*):

```sh
ssh -t homelab 'sudo ~/homelab-website-playbook/scripts/server/audit.sh'
./scripts/verify-site.sh https://<domain> "<your SITE_MARKER>"
./scripts/local/cf-tunnel.py status
```

Things that are **not** automatic, on purpose:
- **Docker and other third-party packages.** `sudo apt upgrade` (or `dnf upgrade`) now
  and then; `audit.sh` counts what's waiting.
- **cloudflared.** You'll get a message when a new version is out. Bump the tag in
  `/srv/cloudflared/<site>/docker-compose.yml`, then `docker compose pull && docker compose up -d`.
- **Backups.** Your site lives in git, so the server is rebuildable in an hour with this
  playbook. Back up anything else you add to it.

When something breaks: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).
