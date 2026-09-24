#!/usr/bin/env python3
"""Every theme defines the full token contract and passes WCAG contrast.

    python3 tests/check-themes.py [theme.css ...]     (default: themes/*.css)

Checked pairs (WCAG 2.x ratios):
    text on bg, text on surface      4.5   body copy
    text-muted on bg / on surface    4.5   secondary copy is still copy
    heading on bg                    4.5
    link on bg                       4.5   links sit inside body text
    accent-ink on accent             4.5   button labels
A theme pulled from Refero (scripts/local/refero-css.py) has different token
names; map it onto this contract first, then run this.
"""
import glob
import os
import re
import sys

REQUIRED = [
    "bg", "surface", "surface-2", "border", "text", "text-muted", "link", "accent", "accent-ink",
    "font-sans", "font-display", "font-mono", "display-weight", "display-tracking",
    "radius", "radius-lg", "radius-button", "shadow",
]
PAIRS = [
    ("text", "bg"), ("text", "surface"), ("text-muted", "bg"), ("text-muted", "surface"),
    ("heading", "bg"), ("link", "bg"), ("accent-ink", "accent"),
]
MIN = 4.5


def tokens(path):
    css = re.sub(r"/\*.*?\*/", "", open(path).read(), flags=re.S)
    return dict(re.findall(r"--([a-z0-9-]+)\s*:\s*([^;]+);", css))


def lum(hexcolor):
    h = hexcolor.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if not re.fullmatch(r"[0-9a-fA-F]{6}", h):
        raise ValueError(hexcolor)
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255
        out.append(c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def check(path):
    t = tokens(path)
    t.setdefault("heading", t.get("text", ""))
    errors = [f"missing --{k}" for k in REQUIRED if k not in t]
    for fg, bg in PAIRS:
        if fg in t and bg in t:
            try:
                r = ratio(t[fg], t[bg])
            except ValueError:
                errors.append(f"--{fg}/--{bg} is not a hex color")
                continue
            if r < MIN:
                errors.append(f"--{fg} on --{bg} is {r:.2f}:1, needs {MIN}:1")
    return errors


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = argv[1:] or sorted(glob.glob(os.path.join(root, "themes", "*.css")))
    if not files:
        print("FAIL no themes found")
        return 1
    bad = 0
    for f in files:
        errs = check(f)
        name = os.path.basename(f)
        if errs:
            bad += 1
            for e in errs:
                print(f"  FAIL {name}: {e}")
        else:
            t = tokens(f)
            print(f"  OK   {name}: text {ratio(t['text'], t['bg']):.1f}:1, muted {ratio(t['text-muted'], t['bg']):.1f}:1, "
                  f"link {ratio(t['link'], t['bg']):.1f}:1, button {ratio(t['accent-ink'], t['accent']):.1f}:1")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
