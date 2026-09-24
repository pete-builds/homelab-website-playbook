#!/usr/bin/env bash
# Create your site from site-starter/, styled with one of the themes.
#
#   ./scripts/local/new-site.sh [--theme midnight|parchment|moss|velvet|path/to/theme.css]
#
# Writes to SITE_DIR (from playbook.env), fills in your domain, name and port,
# and makes the first git commit. Refuses to overwrite an existing directory.
set -euo pipefail
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

theme=midnight
while [ $# -gt 0 ]; do
  case "$1" in
    --theme) theme="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_config
require_vars SITE_NAME DOMAIN SITE_PORT SITE_MARKER SITE_DIR
need_cmd git
SITE_TITLE="${SITE_TITLE:-$DOMAIN}"
SITE_DESCRIPTION="${SITE_DESCRIPTION:-$SITE_TITLE}"
export SITE_NAME DOMAIN SITE_PORT SITE_MARKER SITE_TITLE SITE_DESCRIPTION

case "$SITE_NAME" in *[!a-z0-9-]*|'') die "SITE_NAME must be lowercase letters, digits and dashes" ;; esac
case "$SITE_PORT" in *[!0-9]*|'') die "SITE_PORT must be a number" ;; esac

if [ -f "$theme" ]; then theme_file="$theme"
else theme_file="$PLAYBOOK_ROOT/themes/$theme.css"; fi
[ -f "$theme_file" ] || die "no theme '$theme'. Options: $(for t in "$PLAYBOOK_ROOT"/themes/*.css; do basename "$t" .css; done | tr '\n' ' ')"
python3 "$PLAYBOOK_ROOT/tests/check-themes.py" "$theme_file" >/dev/null \
  || die "theme $theme_file fails the token or contrast check: python3 tests/check-themes.py $theme_file"

dest="${SITE_DIR/#\~/$HOME}"
[ ! -e "$dest" ] || die "$dest already exists. Pick another SITE_DIR or move it aside."
mkdir -p "$(dirname "$dest")"
cp -R "$PLAYBOOK_ROOT/site-starter" "$dest"
cp "$theme_file" "$dest/src/styles/theme.css"
rm -rf "$dest/node_modules" "$dest/dist" "$dest/.astro"

log "Filling in your details"
find "$dest" -type f \( -name '*.astro' -o -name '*.mjs' -o -name '*.json' -o -name '*.yml' \
  -o -name '*.txt' -o -name '*.css' -o -name '*.md' \) -print | while IFS= read -r f; do
  if grep -q '{{[A-Z_]*}}' "$f"; then render_template "$f" "$f"; fi
done
ok "rendered templates with $DOMAIN"

cd "$dest"
git init -q -b main
git add -A
git commit -q -m "Start $DOMAIN from homelab-website-playbook"
ok "created $dest (theme: $(basename "$theme_file" .css))"

cat <<EOF

Next:
  cd $dest
  npm install && npm run dev          # http://localhost:4322, edit src/pages/index.astro
  gh repo create $SITE_NAME --private --source . --push     # or create it on github.com
Then set SITE_REPO in playbook.env to that repo's URL.
EOF
