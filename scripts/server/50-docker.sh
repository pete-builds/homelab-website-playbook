#!/usr/bin/env bash
# Phase 2e: Docker Engine from Docker's own signed repository (not a curl|sh
# script), with sane daemon defaults.
#
# Run as root ON THE SERVER:  sudo ./scripts/server/50-docker.sh
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

need_root
load_config
require_vars ADMIN_USER
detect_os
# shellcheck disable=SC1091
. /etc/os-release

if command -v docker >/dev/null 2>&1; then
  ok "docker already installed: $(docker --version)"
else
  if [ "$OS_FAMILY" = debian ]; then
    distro="$ID"; [ "$ID" = ubuntu ] || [ "$ID" = debian ] || distro=$(printf '%s' "$ID_LIKE" | awk '{print $1}')
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    repo=centos; [ "$ID" = fedora ] && repo=fedora
    dnf install -y -q dnf-plugins-core
    dnf config-manager addrepo --from-repofile="https://download.docker.com/linux/$repo/docker-ce.repo" 2>/dev/null \
      || dnf config-manager --add-repo "https://download.docker.com/linux/$repo/docker-ce.repo"
    dnf install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  ok "installed $(docker --version)"
fi

# live-restore: containers keep running while dockerd itself restarts (e.g. when
#   you patch Docker).
# log-opts: without a cap, container logs grow until the disk is full.
# no-new-privileges: no process in any container can gain privileges via setuid.
# Changes here only take effect after dockerd restarts.
daemon=/etc/docker/daemon.json
want='{
  "live-restore": true,
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}'
install -d -m 755 /etc/docker
if [ -f "$daemon" ] && [ "$(cat "$daemon")" != "$want" ]; then
  cp "$daemon" "$daemon.bak.$(date +%s)"
  warn "replaced an existing $daemon (backup saved beside it)"
fi
printf '%s\n' "$want" > "$daemon"
systemctl enable docker >/dev/null 2>&1
systemctl restart docker
docker info --format '{{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}}' | grep -c 'json-file live-restore=true' >/dev/null \
  || die "dockerd did not pick up $daemon"
ok "daemon: log rotation, live-restore, no-new-privileges"

# Membership in the docker group is root-equivalent: anyone in it can mount the
# host's / into a container. It's granted here so deploys over SSH work without
# a sudo password; the protection is that only your SSH key can log in as
# this user.
usermod -aG docker "$ADMIN_USER"
chown "$ADMIN_USER:$ADMIN_USER" /srv/sites /srv/cloudflared
ok "$ADMIN_USER can run docker (log out and back in for it to apply)"

docker run --rm hello-world >/dev/null && ok "docker runs containers"
