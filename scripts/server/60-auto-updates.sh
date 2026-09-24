#!/usr/bin/env bash
# Phase 2f: scheduled updates, hands off.
#
#   daily        security patches install automatically (unattended-upgrades or
#                dnf-automatic)
#   daily        at REBOOT_TIME the server reboots, but ONLY if a patch needs it
#   weekly       Sunday 05:00, sites rebuild on fresh base images and are
#                health-checked; you're told if a newer cloudflared is out
#   on anything  a one-line message to your phone (see NOTIFY_URL below)
#
# Run as root ON THE SERVER:  sudo ./scripts/server/60-auto-updates.sh
# Optional: NOTIFY_URL=https://ntfy.sh/<random-topic> sudo -E ./scripts/server/60-auto-updates.sh
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars REBOOT_TIME
detect_os
case "$REBOOT_TIME" in [0-2][0-9]:[0-5][0-9]) ;; *) die "REBOOT_TIME must look like 04:30" ;; esac

T="$PLAYBOOK_ROOT/templates/updates"
install -m 755 "$T/homelab-notify" /usr/local/sbin/homelab-notify
install -m 755 "$T/homelab-reboot-if-needed" /usr/local/sbin/homelab-reboot-if-needed
install -m 755 "$T/homelab-refresh-containers" /usr/local/sbin/homelab-refresh-containers
ok "installed helpers in /usr/local/sbin"

if [ -n "${NOTIFY_URL:-}" ]; then
  write_secret_file /etc/homelab-playbook/notify.env "NOTIFY_URL=$NOTIFY_URL"
  ok "wrote /etc/homelab-playbook/notify.env (600)"
elif [ ! -f /etc/homelab-playbook/notify.env ]; then
  warn "no NOTIFY_URL: alerts go to the journal only (journalctl -t homelab-notify)"
fi

if [ "$OS_FAMILY" = debian ]; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat > /etc/apt/apt.conf.d/52homelab-playbook <<'EOF'
// Managed by homelab-website-playbook. Security updates only, from the distro.
// Third-party repos (Docker, etc.) are NOT patched here; `audit.sh` reports
// pending updates so you can apply them with `apt upgrade` when you choose.
Unattended-Upgrade::Origins-Pattern {
        "origin=${distro_id},archive=${distro_codename}-security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=${distro_id}ESMApps,archive=${distro_codename}-apps-security";
        "origin=${distro_id}ESM,archive=${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Reboots are handled by homelab-reboot-check.timer so they happen at one
// predictable time and send a notification first.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
  unattended-upgrade --dry-run >/dev/null 2>&1 || die "unattended-upgrade --dry-run failed; check /etc/apt/apt.conf.d/52homelab-playbook"
  ok "unattended-upgrades: security only, daily"
else
  command -v needs-restarting >/dev/null 2>&1 || dnf install -y -q dnf-utils || true
  conf='[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
reboot = never

[emitters]
emit_via = stdio
'
  printf '%s' "$conf" > /etc/dnf/automatic.conf
  if [ -d /etc/dnf/dnf5-plugins ]; then printf '%s' "$conf" > /etc/dnf/dnf5-plugins/automatic.conf; fi
  timer=""
  for t in dnf5-automatic.timer dnf-automatic.timer; do
    if systemctl list-unit-files "$t" >/dev/null 2>&1; then timer=$t; break; fi
  done
  [ -n "$timer" ] || die "no dnf automatic timer found; install dnf-automatic"
  systemctl enable --now "$timer" >/dev/null
  ok "dnf automatic: security only, via $timer"
fi

cat > /etc/systemd/system/homelab-reboot-check.service <<'EOF'
[Unit]
Description=Reboot if an installed update requires it

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-reboot-if-needed
EOF
cat > /etc/systemd/system/homelab-reboot-check.timer <<EOF
[Unit]
Description=Daily reboot check at $REBOOT_TIME

[Timer]
OnCalendar=*-*-* $REBOOT_TIME:00
Persistent=false

[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/homelab-refresh-containers.service <<'EOF'
[Unit]
Description=Rebuild sites on fresh base images and health-check them
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-refresh-containers
EOF
cat > /etc/systemd/system/homelab-refresh-containers.timer <<'EOF'
[Unit]
Description=Weekly container refresh

[Timer]
OnCalendar=Sun *-*-* 05:00:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF
# Tell you when the box comes back, so a reboot you slept through is visible.
cat > /etc/systemd/system/homelab-booted.service <<'EOF'
[Unit]
Description=Notify after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 30; /usr/local/sbin/homelab-notify "back up after boot, kernel $(uname -r)"'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homelab-reboot-check.timer >/dev/null
systemctl enable homelab-booted.service >/dev/null
if command -v docker >/dev/null 2>&1; then
  systemctl enable --now homelab-refresh-containers.timer >/dev/null
  ok "weekly container refresh enabled"
else
  warn "docker not installed yet; re-run this script after 50-docker.sh to enable the weekly refresh"
fi

log "Scheduled:"
systemctl list-timers --all --no-pager | grep -E 'homelab|apt-daily|dnf' || true

/usr/local/sbin/homelab-notify "automatic updates configured; this is a test message"
ok "sent a test notification. If it didn't reach your phone, check NOTIFY_URL."
