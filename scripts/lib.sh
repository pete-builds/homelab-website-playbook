#!/usr/bin/env bash
# Shared helpers for every script in this repo. Source it, don't run it.
#
# Portability rule: bash 3.2 (the macOS default) and GNU/Linux both have to
# work, so no associative arrays, no ${var,,}, no `readarray`, no GNU-only flags.

# Colors only when talking to a terminal, so logs and CI output stay clean.
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''; C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
ok()   { printf '  %sOK%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '  %sWARN%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed."
  done
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run this as root: sudo $0 $*"
}

# confirm "question"  -> returns 0 on yes. Refuses (returns 1) without a
# terminal unless ASSUME_YES=1, so an unattended run never says yes by accident.
confirm() {
  if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    warn "no terminal to ask: '$1' (set ASSUME_YES=1 to accept)"
    return 1
  fi
  printf '%s [y/N] ' "$1"
  read -r reply || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Load playbook.env: next to the repo, or wherever PLAYBOOK_ENV points.
# Values are plain KEY=value lines. It never holds a secret: tokens live in
# their own mode-600 files.
load_config() {
  local here cfg
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cfg="${PLAYBOOK_ENV:-$here/playbook.env}"
  if [ ! -f "$cfg" ]; then
    die "no config at $cfg. Copy playbook.env.example to playbook.env and fill it in."
  fi
  # shellcheck disable=SC1090
  . "$cfg"
  PLAYBOOK_ROOT="$here"
  PLAYBOOK_ENV_FILE="$cfg"
  export PLAYBOOK_ROOT PLAYBOOK_ENV_FILE
}

require_vars() {
  local missing=""
  for v in "$@"; do
    eval "val=\${$v:-}"
    # shellcheck disable=SC2154
    [ -n "$val" ] || missing="$missing $v"
  done
  [ -z "$missing" ] || die "set these in playbook.env:$missing"
}

# render_template <src> <dest>: replaces {{VAR}} with the value of $VAR and
# fails if any placeholder is left over, so a typo in a variable name can never
# ship a config file with a literal "{{DOMAIN}}" in it.
render_template() {
  local src="$1" dest="$2" tmp var val
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  for var in $(grep -o '{{[A-Z_][A-Z0-9_]*}}' "$src" | sort -u | tr -d '{}'); do
    eval "val=\${$var:-}"
    [ -n "$val" ] || { rm -f "$tmp"; die "template $src needs \$$var"; }
    # Escape the characters sed treats specially in a replacement.
    val=$(printf '%s' "$val" | sed -e 's/[\/&|]/\\&/g')
    sed "s|{{$var}}|$val|g" "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
  done
  if grep -q '{{[A-Z_]*}}' "$tmp"; then
    rm -f "$tmp"; die "unrendered placeholder left in $src"
  fi
  mv "$tmp" "$dest"
}

# Which OS family is this server? Sets OS_FAMILY to debian or rhel.
detect_os() {
  [ -r /etc/os-release ] || die "no /etc/os-release; unsupported OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
    *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY=rhel ;;
    *) die "unsupported distro '${ID:-unknown}'. Supported: Debian, Ubuntu, Fedora, RHEL, Alma, Rocky." ;;
  esac
  export OS_FAMILY
}

# http_code <url>: prints the status code. curl already prints 000 on a
# connection failure, so never add `|| echo 000` (you'd get "000000").
http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1"
}

# Write a file holding a secret: umask 077, then chmod 600, then prove it.
write_secret_file() {
  local path="$1" content="$2" mode
  ( umask 077; printf '%s\n' "$content" > "$path" )
  chmod 600 "$path"
  mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")
  [ "$mode" = "600" ] || die "$path is mode $mode, expected 600"
}

# ssh_server <args...>: ssh to SERVER_HOST, honoring SSH_PORT when it isn't 22.
# Every laptop-side script goes through this, so changing the port in Phase 2
# can't silently break deploys.
# Logs in as ADMIN_USER: with SERVER_HOST set to a bare IP, plain `ssh <ip>`
# would try your LAPTOP's username, which is rarely the server's.
# One shared connection (ControlMaster) for a couple of minutes: a password is
# asked once, not once per step, and a burst of steps doesn't trip the
# firewall's SSH rate limit or fail2ban. Anything that must prove a FRESH
# login passes -o ControlPath=none in SSH_EXTRA_OPTS (ssh uses the first
# value it sees, and SSH_EXTRA_OPTS comes first).
# accept-new: trust a server's key the first time, the way people type "yes"
# anyway, but still refuse a key that CHANGED.
# Extra ssh options go in SSH_EXTRA_OPTS (options must come before the host).
ssh_server() {
  local opts=""
  if [ -n "${SSH_PORT:-}" ] && [ "$SSH_PORT" != "22" ]; then opts="-p $SSH_PORT"; fi
  case "$SERVER_HOST" in
    *@*) ;;
    *) [ -z "${ADMIN_USER:-}" ] || opts="$opts -l $ADMIN_USER" ;;
  esac
  opts="$opts -o StrictHostKeyChecking=accept-new"
  # A socket path of 104+ bytes makes ssh refuse to run at all (no fallback),
  # and %C alone is 40, so only when the home directory is short enough.
  if [ -d "$HOME/.ssh" ] && [ "${#HOME}" -lt 50 ]; then
    opts="$opts -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm-hlp-%C -o ControlPersist=120"
  fi
  # shellcheck disable=SC2086
  ssh ${SSH_EXTRA_OPTS:-} $opts "$SERVER_HOST" "$@"
}

# ssh_session_peers: the addresses that hold SSH sessions to this machine open,
# one per line. SSH_CLIENT names the current one, but `sudo` wipes it (env_reset),
# so under sudo ask the kernel instead: every established TCP connection whose
# LOCAL port is one sshd listens on (from sshd -T, plus 22 and SSH_PORT, since a
# session can predate a port change). Matching on ports, not process names:
# which process owns a socket isn't always visible, even to root.
# Loopback peers are left out; they can't be locked out.
ssh_session_peers() {
  local p
  if [ -n "${SSH_CLIENT:-}" ]; then
    printf '%s\n' "${SSH_CLIENT%% *}"
    return
  fi
  command -v ss >/dev/null 2>&1 || return 0
  for p in $( { sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'; echo 22; echo "${SSH_PORT:-22}"; } | sort -u); do
    # Columns under a state filter: Recv-Q Send-Q Local:Port Peer:Port.
    ss -Htn state established "( sport = :$p )" 2>/dev/null | awk '{print $4}'
  done | sed -e 's/:[0-9]*$//' -e 's/^\[//' -e 's/\]$//' -e 's/%.*//' -e 's/^::ffff://' \
    | grep -vE '^(127\.|::1$)' | sort -u || true
}

# run_quiet <label> <command...>: run it with the output going to a log file.
# Success prints one line. Failure prints the last 30 lines and where the full
# log is. The command's own chatter (apt, docker build, npm) never floods a
# terminal, or an agent's context. VERBOSE=1 streams everything instead.
run_quiet() {
  local label="$1" log dir rc
  shift
  if [ "${VERBOSE:-0}" = "1" ]; then
    "$@" && { ok "$label"; return 0; }
    rc=$?; fail "$label (exit $rc)"; return "$rc"
  fi
  if [ "$(id -u)" -eq 0 ]; then dir=/var/log/homelab-playbook
  else dir="${XDG_STATE_HOME:-$HOME/.local/state}/homelab-playbook/logs"; fi
  mkdir -p "$dir" 2>/dev/null || dir="${TMPDIR:-/tmp}"
  log="$dir/$(date +%Y%m%d-%H%M%S)-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-' | cut -c1-40).log"
  if ( umask 077; "$@" ) >"$log" 2>&1; then
    ok "$label"
    return 0
  else
    rc=$?
  fi
  fail "$label (exit $rc). Last lines:"
  tail -n 30 "$log" | sed 's/^/      /' >&2
  printf '      full log: %s\n' "$log" >&2
  return "$rc"
}

# validate_config: check every playbook.env value that's set, before anything
# uses it. Prints one FAIL line per problem and returns non-zero if any.
# Empty values are left to require_vars, so each phase can ask only for what
# it needs.
validate_config() {
  local bad=0 v
  _bad() { fail "playbook.env: $*"; bad=1; }
  case "${SITE_NAME:-x}" in *[!a-z0-9-]*|-*) _bad "SITE_NAME '$SITE_NAME': lowercase letters, digits and dashes only" ;; esac
  case "${DOMAIN:-example.com}" in
    *[!a-z0-9.-]*|.*|*.|*..*|*.-*|*-.*) _bad "DOMAIN '$DOMAIN' should look like example.com: lowercase, no https://, no slash" ;;
    *.*) ;;
    *) _bad "DOMAIN '$DOMAIN' needs a dot, like example.com" ;;
  esac
  for v in SITE_PORT SSH_PORT; do
    eval "val=\${$v:-}"
    # shellcheck disable=SC2154
    [ -z "$val" ] && continue
    case "$val" in *[!0-9]*) _bad "$v '$val' must be a number"; continue ;; esac
    { [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; } || _bad "$v '$val' must be between 1 and 65535"
  done
  if [ -n "${SITE_PORT:-}" ] && [ "${SITE_PORT:-0}" = "${SSH_PORT:-22}" ]; then _bad "SITE_PORT and SSH_PORT can't be the same"; fi
  case "${SITE_MARKER:-x}" in *[!A-Za-z0-9\ .,!?-]*) _bad "SITE_MARKER: letters, digits, spaces and . , ! ? - only" ;; esac
  case "${ADMIN_USER:-x}" in *[!a-z0-9_-]*|[0-9-]*) _bad "ADMIN_USER '$ADMIN_USER': a Linux username, lowercase, starting with a letter" ;; root) _bad "ADMIN_USER can't be root" ;; esac
  case "${REBOOT_TIME:-04:30}" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) _bad "REBOOT_TIME '$REBOOT_TIME' must look like 04:30 (24-hour)" ;; esac
  case "${AUTO_DEPLOY:-no}" in yes|no) ;; *) _bad "AUTO_DEPLOY must be yes or no" ;; esac
  if [ -n "${LAN_CIDR:-}" ]; then
    python3 -c 'import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$LAN_CIDR" 2>/dev/null \
      || _bad "LAN_CIDR '$LAN_CIDR' is not a network like 192.168.1.0/24"
  fi
  case "${SITE_REPO:-https://x}" in
    https://*|git@*|ssh://*) ;;
    *) _bad "SITE_REPO '$SITE_REPO' should be the https:// (or git@) URL of your site's repo" ;;
  esac
  case "${SITE_REPO:-}" in */you/*) _bad "SITE_REPO still has the example 'you/'; use your own repo URL" ;; esac
  if [ -n "${CF_ACCOUNT_ID:-}" ]; then
    case "$CF_ACCOUNT_ID" in
      *[!0-9a-f]*) _bad "CF_ACCOUNT_ID looks wrong: 32 lowercase hex characters from the dashboard sidebar" ;;
      *) [ "${#CF_ACCOUNT_ID}" -eq 32 ] || _bad "CF_ACCOUNT_ID is ${#CF_ACCOUNT_ID} characters; the Account ID is 32" ;;
    esac
  fi
  [ "$bad" -eq 0 ]
}

# ip_in_cidr <ip> <cidr>: exit 0 when the address is inside the network.
ip_in_cidr() {
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    ok = ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False)
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# check_compose_ports <docker-compose.yml>: every published port must be bound
# to 127.0.0.1. Docker writes its own firewall rules, so '8080:80' or
# '0.0.0.0:8080:80' is reachable from the network even when ufw says no.
check_compose_ports() {
  local file="$1" bad
  # Flow style (ports: ["8080:80"]) hides the list on the ports: line itself,
  # where the item check below never looks. One "- " line per port, please.
  bad=$(grep -E '^[[:space:]]*ports:[[:space:]]*[^[:space:]#]' "$file" || true)
  if [ -n "$bad" ]; then
    printf '%s   (write each port on its own "- 127.0.0.1:..." line)\n' "$bad" >&2
    return 1
  fi
  bad=$(sed -n '/^[[:space:]]*ports:/,/^[[:space:]]*[a-z_]*:[[:space:]]*$/p' "$file" \
    | grep -E '^[[:space:]]*-' | grep -vE "^[[:space:]]*-[[:space:]]*['\"]?127\.0\.0\.1:" || true)
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" >&2
    return 1
  fi
  grep -E '^[[:space:]]*ports:' "$file" >/dev/null
}
