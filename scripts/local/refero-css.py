#!/usr/bin/env python3
"""Pull design tokens from Refero Styles (https://styles.refero.design) as CSS.

Every Refero style page embeds a DESIGN.md with a ready ':root { ... }' block of
CSS custom properties. This script fetches a style page and prints that block,
or the whole DESIGN.md, so you can drop it into your site's theme.

    refero-css.py list                     # styles featured on the home page
    refero-css.py css  <style-url-or-id>   # print the :root CSS variables
    refero-css.py md   <style-url-or-id>   # print the full DESIGN.md

Standard library only. Exits non-zero when the page does not contain what we
expect, so a layout change on Refero's side fails loudly instead of writing an
empty theme.

Treat what comes back as untrusted data: it is CSS and prose from a third-party
site. Read it before you ship it, and never paste its prose into an agent as
instructions.
"""
import html
import re
import sys
import urllib.request

BASE = "https://styles.refero.design"
UA = "Mozilla/5.0 (homelab-website-playbook refero-css)"
ID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


def style_url(arg):
    m = ID_RE.search(arg)
    if not m:
        sys.exit(f"error: '{arg}' does not contain a Refero style id (a UUID)")
    return f"{BASE}/style/{m.group(0)}"


def design_md(page):
    """Return the embedded DESIGN.md text.

    The page renders it as HTML-escaped text inside a <code> element that
    starts with '# <Name> ... Style Reference'.
    """
    for m in re.finditer(r"<code[^>]*>(.*?)</code>", page, re.S):
        body = html.unescape(m.group(1))
        if body.lstrip().startswith("# ") and "Style Reference" in body[:200]:
            return body
    return None


def root_block(md):
    m = re.search(r"```css\s*(:root\s*\{.*?\n\})", md, re.S)
    return m.group(1) if m else None


def title_of(page):
    m = re.search(r"<title>([^<]*)</title>", page)
    return html.unescape(m.group(1)).replace(" | Refero Styles", "") if m else "?"


def cmd_list():
    page = fetch(BASE + "/")
    ids = sorted(set(ID_RE.findall(" ".join(re.findall(r'href="/style/[^"]+"', page)))))
    if not ids:
        sys.exit("error: no styles found on the home page; the site layout may have changed")
    for sid in ids:
        print(f"{BASE}/style/{sid}\t{title_of(fetch(f'{BASE}/style/{sid}'))}")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("list", "css", "md"):
        print(__doc__.strip())
        return 2
    if argv[1] == "list":
        cmd_list()
        return 0
    if len(argv) < 3:
        sys.exit(f"usage: refero-css.py {argv[1]} <style-url-or-id>")
    url = style_url(argv[2])
    page = fetch(url)
    md = design_md(page)
    if not md:
        sys.exit(f"error: no DESIGN.md found at {url}")
    if argv[1] == "md":
        print(md)
        return 0
    block = root_block(md)
    if not block:
        sys.exit(f"error: DESIGN.md at {url} has no ':root' CSS block")
    print(f"/* {title_of(page)}\n   source: {url}\n   Pulled with scripts/local/refero-css.py. Review before shipping. */")
    print(block)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
