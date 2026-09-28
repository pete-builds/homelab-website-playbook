# Troubleshooting

Every entry here is a failure someone actually hit, or one the scripts are
built to catch. Most are silent: something that looks fine and isn't.

**Start with `./playbook why`.** It reads the log of your last `./playbook` run,
matches it against every failure below, and prints the cause, the one fix, and a
link to the section here. `./playbook status` shows which phase is broken right
now. You only need to read further when those two don't settle it.

## Running the playbook

### Steps that need your terminal

`./playbook server bootstrap`, `ssh`, `harden`, `watch` and `audit` ask for your
server password (sudo). An agent has no keyboard to type it on, so it prints the
command instead of running it. Open Terminal, `cd` into this folder, paste the line.
The `ssh` step also needs a second terminal for `./playbook server test-login`.

### playbook.env

Every script validates it first and names the line that's wrong. The usual ones:
`SITE_NAME` with capitals or spaces, `DOMAIN` with `https://` or a slash in it,
`SITE_MARKER` with characters HTML would escape (the live check would never find
it), and `LAN_CIDR` that isn't a network like `192.168.1.0/24`. `./playbook doctor`
checks the whole file.

## The server

### SSH refuses your key

`Permission denied (publickey)`. The server doesn't have your laptop's public key
for `ADMIN_USER`, or `ADMIN_USER` isn't the user you created at install.
`./playbook server key` installs the key (it asks for that user's password once).

### The server's identity changed

`REMOTE HOST IDENTIFICATION HAS CHANGED`. If you reinstalled the server, this is
expected: `ssh-keygen -R <SERVER_HOST>` and connect again. If you didn't, stop:
something else is answering at that address.

### The server doesn't answer

A timeout, `No route to host`, or `Connection refused`. In order: is it on? Did its
address change (give it a DHCP reservation in your router)? Does `SSH_PORT` match?
Has fail2ban banned your laptop (next section)?

### Everything fails from your laptop

fail2ban may have banned your laptop after failed logins. From the server's own
keyboard, or another device on your network: `sudo fail2ban-client status sshd`,
then `sudo fail2ban-client set sshd unbanip <ip>`. A ban looks exactly like "the
server is down", so check this before concluding anything is broken.

### Locked out of SSH

If `10-harden-ssh.sh` did it, wait 5 minutes: it reverts unless you confirmed.
If the firewall step refused to run with `OUTSIDE LAN_CIDR`, it changed nothing:
fix `LAN_CIDR` (or empty it) and run it again. Otherwise use the server's keyboard
and screen, then `sudo sshd -T | grep -i password`.

### SSH changes didn't apply

sshd keeps the *first* value it reads, and files in `sshd_config.d/` are read in
name order: a `99-` file loses to cloud-init's `50-cloud-init.conf`. That's why ours
is `00-`. The truth is `sudo sshd -T`, not the file. On Ubuntu 22.10+, `ssh.socket`
listens on its own port; `10-harden-ssh.sh` hands listening back to `ssh.service`.

### The package manager is busy

`Could not get lock /var/lib/dpkg/lock`. Right after the first boot the server
installs updates by itself. The scripts wait up to 10 minutes for the lock; if
it's still held, run the same step again later. Every step is safe to re-run.

### The server has no internet

`Temporary failure resolving`. Check its cable and your router. On the server:
`ping -c1 1.1.1.1` (route) and `getent hosts github.com` (DNS).

### Docker came from a snap

Ubuntu's installer offers Docker as a snap. The snap ignores this playbook's
Docker settings and can't read `/srv`. `sudo snap remove --purge docker`, then
`./playbook server harden` installs Docker from Docker's own repository.

### Docker permission denied

`permission denied while trying to connect to the Docker daemon`. Joining the
docker group only applies to new logins. Each `./playbook server` step is a new
login, so just run the step again.

### A container port is reachable even though ufw blocks it

Docker writes its own firewall rules ahead of ufw. Only ever publish ports on
`127.0.0.1:`. `audit.sh` fails any container published on all interfaces, and
`70-site.sh` refuses a compose file that would.

### A port is already in use

`port is already allocated`. Something else on the server uses `SITE_PORT` (or
`TUNNEL_METRICS_PORT`, 20241). Pick another in `playbook.env` and run the step again.

### The disk is full

`no space left on device`. `docker system prune -af` on the server removes unused
images; `df -h /` shows what's left. The weekly refresh prunes old images and
build cache on its own.

### Automatic updates stopped

`audit.sh` fails when security updates haven't succeeded for 3 days. A failed
run doesn't alert by itself (it still exits 0), which is why the audit checks the
date of the last success. `sudo unattended-upgrade -d | tail -40` shows why;
usually a third-party repository is broken. Docker and cloudflared are never
updated automatically, on purpose: `audit.sh` counts what's waiting.

### No notifications arrive

`sudo /usr/local/sbin/homelab-notify test`. Failures are logged:
`journalctl -t homelab-notify`. Email isn't supported on purpose: many ISPs block
outbound mail and it fails without a word.

## Building the site

### Node.js is too old

Astro needs Node.js 22.12 or newer. Install the LTS from https://nodejs.org, open
a new terminal, `./playbook doctor`.

### The build fails

Every line starting with `FAIL` names the page and the problem. The site's checks
(`scripts/check-dist.mjs`) run on your laptop and again inside the server's build,
so a site that fails them can never replace the one that's live. Run
`./playbook site check` until it passes.

### Something works in dev but not live

The security policy (CSP) exists only in nginx, never in `npm run dev`. Inline
`<script>`, fonts from a CDN, embedded maps and external images are all blocked
live. The build's checks catch inline scripts and external hosts the policy
doesn't allow; host the file yourself, or add its host to the CSP line in
`nginx.conf`.

### A map or image shows "API KEY REQUIRED"

Some tile and image services answer `200 OK` with the error drawn into the
picture. No status code can catch that: look at it.

## Going live

### Cloudflare shows 502

The tunnel is up, the site behind it isn't answering. `./playbook server site`.

### The home page answers 404

With no security headers, it's the tunnel's own catch-all: its routing has no rule
for this hostname. `./playbook server tunnel` re-applies it for your domain and www.

### Error 1033: the tunnel isn't connected

Cloudflare has no running connector for your tunnel (the page may say 530).
`./playbook status` shows whether the connector is ready. A wrong or revoked
token shows up in `docker logs cloudflared-<site>` as "not valid":
`./playbook server tunnel` fetches a fresh one and installs it.

### Error 1014

Your domain and your tunnel are in different Cloudflare accounts. Use one account
for both. `cf-tunnel.py` refuses to create this.

### The domain doesn't resolve

A tunnel's "hostname route" in the dashboard is **not** a DNS record, and a CNAME
to `cfargotunnel.com` only works **proxied** (orange cloud).
`./playbook server tunnel` makes both records correctly. If it stops on an existing
record, that's usually a registrar's parking page: `./playbook tunnel create
--replace-dns` after you've looked at it. A domain registered elsewhere needs its
nameservers moved to Cloudflare first. `dig A yourdomain` can come back empty:
Cloudflare flattens an apex CNAME and may answer with IPv6 only. Test with
`curl -sI https://yourdomain`, not `dig A`.

### A Cloudflare challenge page

`INDETERMINATE` from a check means Cloudflare showed a "Just a moment..." bot check
instead of your page. Automated checks from servers and GitHub's runners get
these. If real visitors see it too: dashboard > Security > Settings, lower the
security level or turn off Bot Fight Mode.

### The site looks old

See which build is live: `curl -s https://yourdomain/ | grep 'name="build"'`. HTML
and everything outside `/assets/` is sent `no-cache`, so an old build means a
Cache Rule someone added in Cloudflare. Hashed files under `/assets/` are cached
for a year on purpose; their names change whenever they change.

### The security headers disappeared

An `add_header` inside a `location` block silently drops every `add_header` from
the server block. Keep them at server level only. `verify-site.sh` fails when one
goes missing.

### The home page downloads instead of displaying

A `types { }` block in nginx replaces its whole MIME map. Use `default_type`
inside a `location` instead. `verify-site.sh` fails anything not served as
`text/html`.

## Shipping

### A deploy failed

What `./playbook deploy` says tells you which kind:
- **"still live, untouched"**: the build failed; nothing changed. `./playbook site check` shows why.
- **"put the previous one back"**: the new version built but wasn't healthy, so the
  last good one is live again. Check `nginx.conf` and anything about how pages are served.
- **"THE SITE IS DOWN"**: the new version and the rollback both failed.
  `./playbook server site` rebuilds main; `./playbook why` reads its log.
- **"uncommitted changes"** or **"both changed"**: commit, or `git pull --rebase`.
  Never force-push, never edit files on the server.

With auto-deploy on, the same outcomes arrive as notifications. A commit that
failed once isn't retried, and a rollback pauses auto-deploy until your next
`./playbook deploy`.

### Private site repo

The server needs read access. On the server:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/site_deploy -N '' -C "deploy key for mysite"
cat ~/.ssh/site_deploy.pub
```

Add that public key to the repo on GitHub under **Settings > Deploy keys** (read-only).
Then in `~/.ssh/config` on the server:

```
Host github-mysite
    HostName github.com
    User git
    IdentityFile ~/.ssh/site_deploy
    IdentitiesOnly yes
```

and set `SITE_REPO=git@github-mysite:you/mysite.git`.

## Buying a domain

### Buying a domain

- **A checker says everything is available.** It's broken. Always include a domain
  you know is taken in the same check.
- **`action_required` or `blocked`.** Finish it in the dashboard under Domain
  Registration. The script stops polling on purpose; don't retry the purchase.
- **Premium or no price.** The script only buys standard-priced names at a price
  Cloudflare actually quoted. Pick another name.
- **The domain went "on hold" a couple of weeks later.** The registrant email was
  never verified. Check your inbox (and spam) for Cloudflare's verification mail.

### The Cloudflare token

`HTTP 403` or "missing a permission": the token lacks a permission the step needs,
or expired. Recreate it with the permissions listed in PLAYBOOK.md Phase 3 and save
it the way shown there. `CF_ACCOUNT_ID` is the Account ID in the right sidebar of
any dashboard page.
