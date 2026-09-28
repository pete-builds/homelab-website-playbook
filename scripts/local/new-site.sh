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
validate_config || die "fix playbook.env first"
need_cmd git
git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || die "git doesn't know who you are yet. Run:
  git config --global user.name  \"Your Name\"
  git config --global user.email \"you@example.com\""
SITE_TITLE="${SITE_TITLE:-$DOMAIN}"
SITE_DESCRIPTION="${SITE_DESCRIPTION:-$SITE_TITLE}"
export SITE_NAME DOMAIN SITE_PORT SITE_MARKER SITE_TITLE SITE_DESCRIPTION


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
# Free text (title, description, marker) goes through JSON encoding, so quotes
# and apostrophes can't break the build. It's MERGED into the starter's
# site.json, which also holds the url, the nav and the share image; the render
# loop below fills {{DOMAIN}} in the url. Everything else is validated above.
python3 - "$dest/src/site.json" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    site = json.load(f)
site.update(title=os.environ["SITE_TITLE"], description=os.environ["SITE_DESCRIPTION"],
            marker=os.environ["SITE_MARKER"])
with open(path, "w", encoding="utf-8") as f:
    json.dump(site, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
# The site's uptime workflow runs this same verifier against the live site.
mkdir -p "$dest/scripts"
cp "$PLAYBOOK_ROOT/scripts/verify-site.sh" "$dest/scripts/verify-site.sh"
find "$dest" -type f \( -name '*.astro' -o -name '*.mjs' -o -name '*.json' -o -name '*.yml' \
  -o -name '*.txt' -o -name '*.css' -o -name '*.md' \) -not -path '*/node_modules/*' -print | while IFS= read -r f; do
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
  ./playbook site dev                  # preview at http://localhost:4322
  ./playbook site post "Hello"         # a blog post (the model only writes the words)
  cd $dest && gh repo create $SITE_NAME --public --source . --push
Then set SITE_REPO in playbook.env to that repo's URL. Its README says what's where.
EOF
