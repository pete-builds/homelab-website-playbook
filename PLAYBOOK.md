# The Playbook

From a spare computer to your own website on your own domain, served from your house,
hardened, patching itself, watching itself, with nothing exposed to the internet.

Budget an afternoon for the first pass. Every phase ends with a check that proves it
worked. Don't move on until it passes.

```
 your laptop                     your server (at home)                    the internet
 ───────────                     ─────────────────────                    ────────────
 edit site ──git push──▶ GitHub ◀──git pull── /srv/sites/<site>
 ./playbook ──ssh──────────────▶ nginx container
                                 127.0.0.1:8080 (loopback only)
                                       ▲
                                       │ plain HTTP, never leaves the box
                                 cloudflared container ──outbound──▶ Cloudflare edge ◀── visitors
                                                         tunnel      HTTPS, your domain
 firewall: deny ALL inbound except SSH. Router: forward nothing.
```

**Everything is one command: `./playbook`.** On its own it shows where you are and the
next command to run. When anything fails, `./playbook why` says what it means and how
to fix it. `./playbook guide <N>` prints just one phase of this document.

With Claude Code, open this folder and say **"set me up"**: the `morpheus` agent walks
you through it, running what it can and handing you the lines only you can type.

---

## Phase 0: Your laptop

You need `git`, `ssh`, `python3`, `curl`, and Node.js 22.12 or newer (the LTS from
[nodejs.org](https://nodejs.org)).

```sh
git clone https://github.com/pete-builds/homelab-website-playbook
cd homelab-website-playbook
cp playbook.env.example playbook.env      # then fill it in; every line is explained
./playbook doctor
```

No SSH key yet? `ssh-keygen -t ed25519` and accept the defaults.

**Check:** `./playbook doctor` shows no `FAIL` lines.

## Phase 1: The server

**Hardware.** Any 64-bit machine with 4 GB of RAM or more: an old laptop, a used mini PC,
a Raspberry Pi 4/5. Wired Ethernet beats Wi-Fi. It will run 24/7 on a few watts.

**Install** [Ubuntu Server 24.04 LTS](https://ubuntu.com/download/server). Debian 13 is
tested just as thoroughly. Fedora and Rocky/Alma are supported by the scripts but not
yet covered by CI. During the install:
- create your user. That name goes in `ADMIN_USER`.
- tick **Install OpenSSH server**. Skip the offered Docker snap: the playbook installs
  Docker properly later, and the snap gets in its way.
- no desktop. Headless means no monitor needed after this.
- Debian: if you set a root password, the installer leaves out sudo. That's fine: the
  bootstrap step notices and asks for the root password instead, once.

**In your router**, give the server a fixed address (a "DHCP reservation"). That address
goes in `SERVER_HOST`. If you prefer a name, add it to `~/.ssh/config` on the laptop
(`Host homelab` / `HostName 192.168.1.50`) and set `SERVER_HOST=homelab`.

Then, from the laptop:

```sh
./playbook server key          # puts your key on the server; asks for your password once
./playbook server bootstrap    # packages, timezone, your key and sudo, the playbook's folders
```

`bootstrap` copies this playbook and your `playbook.env` to the server itself; every
`./playbook server` step does, so you never need scp. Safe to re-run.

**Check:** `./playbook status` shows phase 1 done.

## Phase 2: Harden it

Two commands. The first changes how you log in, so it has a safety net:

```sh
./playbook server ssh          # key-only SSH, no root login
./playbook server harden       # firewall, fail2ban, kernel, Docker, automatic updates
```

**`ssh` needs a second terminal.** Before running it, open another terminal in this
folder. When the script asks, run `./playbook server test-login` there: it makes a
fresh login with your key and proves a password is refused. Type `yes` in the first
terminal only when it says PASS. If you don't within 5 minutes, a timer undoes the
change, even if your connection dropped. It also refuses to run at all if your user
has no key, because turning passwords off then would lock you out.

**`LAN_CIDR`.** If you set it, SSH is accepted only from that network. The firewall
step checks every open SSH session and refuses a value that would lock you out. Not
sure what your network is? Leave it empty.

**`harden` sets up the hands-off part**, and asks where to send messages:

| When | What |
|---|---|
| daily | security updates install automatically, and only security updates |
| daily at `REBOOT_TIME` | reboots **only if** an update needs it, and tells you first |
| Sundays 05:00 | rebuilds your site on a fresh nginx image, puts the old one back if the new one is unhealthy, says "all good" (or what isn't), and tells you if a newer cloudflared exists |
| after any reboot | "back up", with a health verdict once Phase 8 is done |
| any scheduled job fails | a message saying which, and where to look |

[ntfy](https://ntfy.sh) is free: install the app, subscribe to a long random topic name
(anyone who guesses it can read it), and paste `https://ntfy.sh/<topic>` when asked.
A Discord webhook URL works too. Email doesn't: many ISPs block outbound mail, and it
fails without a word.

**Check:**
```sh
./playbook server audit          # no FAIL lines (asks for your password)
./playbook server firewall-test  # the server listens on a port; your laptop must NOT reach it
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

**An API token.** Dashboard: **My Profile > API Tokens > Create Token > Create Custom Token**.
- Account: **Cloudflare Tunnel: Edit**
- Zone: **DNS: Edit**, **Zone: Read**, and **Zone Settings: Edit** (so the tunnel step
  can turn on "Always Use HTTPS" for you; without it you flip that switch yourself)
- To buy through the script too: the Registrar permission with write/edit access
  (Cloudflare's [Registrar API guide](https://developers.cloudflare.com/registrar/registrar-api/)
  calls it "Registrar write permissions").
- Account Resources: your account. Zone Resources: all zones in the account.

Save it where only you can read it (it's shown once):
```sh
mkdir -p ~/.config/homelab-playbook
( umask 077; pbpaste > ~/.config/homelab-playbook/cloudflare.token )   # macOS, after copying it
# Linux: ( umask 077; cat > ~/.config/homelab-playbook/cloudflare.token ), paste, Enter, Ctrl-D
```

**Shop and buy:**
```sh
./playbook domain search "handmade furniture" --tld com,co,studio
./playbook domain check mapleandpine.com mapleandpine.co cloudflare.com
./playbook domain register mapleandpine.com
```
Put a domain you know is taken (like `cloudflare.com`) in every `check`. If it ever says
*available*, the check is broken; don't trust it.

`register` re-checks the price, shows it, and asks you to type the domain name and a
code it shows at that moment. Registrations are **non-refundable**. Auto-renew is
switched on so it can't lapse. Or ask Claude (*"find me a domain for a handmade
furniture shop"*): the `merovingian` agent shops with you and hands you the line to buy.

**Right after buying:** click the verification link Cloudflare emails to your registrant
address. Unverified domains get suspended within about two weeks.

Put the domain in `DOMAIN`.

**Check:** `./playbook domain status <domain>` says `active`.

## Phase 4: Your site

```sh
./playbook site new --theme parchment     # or midnight, moss, velvet
./playbook site dev                       # http://localhost:4322
```

The site has its own `README.md` that says what lives where. The short version:

| To | Run | Then |
|---|---|---|
| write a blog post | `./playbook site post "Title"` | write in the file it prints; set `draft: false` |
| add a page | `./playbook site page "Title"` | edit the file it prints; it's in the nav already |
| rename the site | `./playbook site meta --title "..." --description "..."` | |
| change the look | `./playbook site theme moss` | |
| check everything | `./playbook site check` | the same build and checks the server runs |

`src/site.json` holds the title, description, address, nav and share picture.
The `SITE_MARKER` sentence from `playbook.env` stays on the home page: the live checks
look for it.

**Themes** are described in [`themes/README.md`](themes/README.md), including how to make
your own from any design system on [Refero Styles](https://styles.refero.design).
Or ask the `link` agent: *"make it feel like Wise"*.

**Put it on GitHub** so the server can pull it:

```sh
cd ~/sites/mysite                                  # whatever SITE_DIR is
gh repo create mysite --public --source . --push
```

and set `SITE_REPO` to its URL. Public is simplest: it's a website, it'll be public anyway.
For a private repo, see [Private site repo](docs/TROUBLESHOOTING.md#private-site-repo).

The repo arrives with three GitHub workflows: every push is built exactly as the server
will build it, the live site is checked every 6 hours (a `site-down` issue opens, and
emails you, if it fails), and Dependabot proposes updates once a month.

**Check:** `./playbook site check` ends with `check-dist OK`.

## Phase 5: Run it on the server

```sh
./playbook server site
```

It clones your site, builds it in Docker (running the site's own checks inside the
build), and starts nginx on `127.0.0.1` only. Nobody else can reach it yet. That's the point.

**Check:** it ends with `home 200, missing page 404`.

## Phase 6: Go live through the tunnel

```sh
./playbook server tunnel
```

This creates the tunnel, routes your domain and `www` to your site, creates the DNS
records, turns on "Always Use HTTPS", and saves the tunnel's token to a private file.
Then it sends that token to the server over SSH (never on screen, never in a command
line), starts the connector, waits until Cloudflare confirms it, and checks your
domain from the outside.

**Check:** it ends with `<domain> is live`. Open it on your phone, on mobile data.

## Phase 7: Everyday life

Edit, commit, then:

```sh
./playbook deploy
```

It refuses uncommitted work, pulls anything merged on GitHub first, runs your checks,
pushes, builds the new version on the server, **puts the previous one back by itself**
if the new one isn't healthy, and finally proves the live site is serving the exact
commit you just made. Changed your mind?

```sh
./playbook rollback
```

**Or let the server deploy for you.** Set `AUTO_DEPLOY=yes` in `playbook.env` and run
`./playbook server watch` (Phase 8). Then any push to `main` (from the laptop, from
GitHub's website, or a Dependabot update you merge) goes live within about five
minutes, with the same checks, proof and rollback, and a message saying so.

## Phase 8: Let it watch itself

```sh
./playbook server watch
```

| How often | What |
|---|---|
| every 10 minutes | checks the site on the server, the tunnel connector, the public site through Cloudflare, and disk space. Tells you when something breaks (two checks in a row, so one blip isn't a page), restarts a stuck container once, and tells you when it's back |
| daily | the full security audit; tells you when a new problem appears |
| after a reboot | "back up, site healthy", or exactly what isn't |

It also offers a **heartbeat**. A dead server, or a power cut, can't send a message,
so nothing above can tell you about it. A free push monitor can: make a check at
[healthchecks.io](https://healthchecks.io) (period 10 minutes, grace 30), paste its
ping URL when asked, and it emails you when the pings stop.

From then on, `./playbook status` shows the latest watch and audit results without
asking for your password.

Things that are **not** automatic, on purpose:
- **Docker and other third-party packages.** `sudo apt upgrade` (or `dnf upgrade`) now
  and then; the audit counts what's waiting.
- **cloudflared.** The weekly message says when a new version is out. Then:
  `./playbook server tunnel-update` (it puts the old one back if the new one doesn't connect).
- **Backups.** Your site lives in git, so the server is rebuildable in an hour with this
  playbook. Back up anything else you add to it.

When something breaks: `./playbook why`, then [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).
