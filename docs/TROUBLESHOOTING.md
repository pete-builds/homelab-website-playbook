# Troubleshooting

Every entry here is a failure someone actually hit. Most are silent: something that
looks fine and isn't. The scripts check for all of them, but knowing the shape helps
when you're debugging by hand.

## The site

**Cloudflare shows 502.** The tunnel is up but nginx isn't answering. On the server:
`docker ps` and `curl -s http://127.0.0.1:<SITE_PORT>/healthz`. Start it with `70-site.sh`.

**Cloudflare shows 503.** The tunnel has no ingress rule for that hostname. Re-run
`./scripts/local/cf-tunnel.py create`; it's idempotent.

**Error 1016.** The connector isn't running. On the server:
`docker logs cloudflared-<site>`. A revoked token shows up here.

**Error 1014 (CNAME Cross-User Banned).** Your domain and your tunnel are in different
Cloudflare accounts. Use one account for both. `cf-tunnel.py` refuses to create this.

**The domain doesn't resolve at all.** There's no DNS record. A tunnel's "hostname route"
in the dashboard is **not** a DNS record, and a CNAME to `cfargotunnel.com` only works
**proxied** (orange cloud). `cf-tunnel.py create` makes both records correctly.

**`dig A yourdomain` returns nothing.** Cloudflare flattens an apex CNAME and can answer
with IPv6 only. Test with `curl -sI https://yourdomain`, not `dig A`.

**It deployed, but the site looks old.** See which build is live:
`curl -s https://yourdomain/ | grep 'name="build"'`. HTML is served `no-cache`, so if it's
old, look for a Cache Rule someone added in Cloudflare. Hashed files under `/assets/`
are cached for a year on purpose; their names change whenever they change.

**Something works in `npm run dev` but not live.** The security policy (CSP) exists only
in nginx, never in the dev server. Inline `<script>`, fonts from a CDN, embedded maps and
external images are all blocked live. `npm run check` catches inline scripts; for the
rest, add the host to the CSP line in `nginx.conf`.

**A map or image loads but shows "API KEY REQUIRED".** Some tile and image services answer
`200 OK` with an error drawn into the picture. A status code can't catch that: look at it.

**The security headers disappeared.** An `add_header` inside a `location` block silently
drops every `add_header` from the server block. Keep them at server level only.
`verify-site.sh` fails when one goes missing.

**The home page downloads instead of displaying.** A `types { }` block in nginx replaces
its whole MIME map. Use `default_type` inside a `location` instead.

## The server

**Locked out of SSH.** If `10-harden-ssh.sh` did it, wait 5 minutes: it reverts unless you
confirmed. Otherwise use the server's keyboard and screen, then `sudo sshd -T | grep -i password`.

**Everything "fails" from your laptop, but the server looks fine.** fail2ban may have
banned your laptop. On the server: `sudo fail2ban-client status sshd`, then
`sudo fail2ban-client set sshd unbanip <ip>`. Test from the server's own LAN before
concluding anything is down.

**SSH changes didn't apply.** sshd keeps the *first* value it reads, and files in
`sshd_config.d/` are read in name order: a `99-` file loses to cloud-init's
`50-cloud-init.conf`. That's why ours is `00-`. The truth is `sudo sshd -T`, not the file.

**SSH port change ignored (Ubuntu 22.10+).** `ssh.socket` listens on its own port.
`10-harden-ssh.sh` switches back to `ssh.service` for you.

**A container port is reachable even though ufw blocks it.** Docker writes its own
firewall rules ahead of ufw. Only ever publish ports on `127.0.0.1:`. `audit.sh` fails
any container published on all interfaces.

**`docker: permission denied` right after 50-docker.sh.** Log out and back in; group
changes need a fresh session.

**"Automatic updates" but Docker is old.** Only the distro's security updates are
automatic. `sudo apt upgrade` for the rest; `audit.sh` tells you how many are waiting.

**No notifications arrive.** Send a test: `sudo /usr/local/sbin/homelab-notify test`.
Failures are logged: `journalctl -t homelab-notify`.

## Buying a domain

**A checker says everything is available.** It's broken. Always include a domain you know
is taken in the same check.

**Registration says `action_required` or `blocked`.** Finish it in the dashboard under
Domain Registration. The script stops polling on purpose.

**The domain went "on hold" a couple of weeks later.** The registrant email was never
verified. Check your inbox (and spam) for Cloudflare's verification mail.

## Private site repo

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
