#!/usr/bin/env bash
# Validate server templates inside real Ubuntu and Debian containers.
#   ./tests/run-linux-checks.sh            (needs Docker)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }
rc=0
for image in ubuntu:24.04 debian:13; do
  docker run --rm -v "$root:/repo:ro" "$image" bash /repo/tests/linux/in-container.sh || rc=1
  # The real scripts, end to end (systemd stubbed; ufw needs NET_ADMIN).
  docker run --rm --cap-add NET_ADMIN -v "$root:/repo:ro" "$image" bash -c \
    'apt-get update -qq >/dev/null && apt-get install -y -qq sudo iproute2 procps >/dev/null 2>&1 && bash /repo/tests/linux/smoke-scripts.sh' || rc=1
done
exit "$rc"
