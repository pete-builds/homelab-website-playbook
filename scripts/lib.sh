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
  export PLAYBOOK_ROOT
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
