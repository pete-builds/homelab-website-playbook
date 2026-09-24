# Themes

Four starting looks. Each is one CSS file of design tokens; `site-starter/src/styles/base.css`
builds the whole site from them, so swapping the file restyles everything.

| Theme | Feels like | Studied from (Refero Styles) |
|---|---|---|
| `midnight` | a precise instrument at night. Near-black, one electric lime accent, hairline borders | [Linear](https://styles.refero.design/style/90ce5883-bb24-4466-93f7-801cd617b0d1), [Raycast](https://styles.refero.design/style/3b6a17f0-3bdf-418c-a95e-0b89e5a8b2f8) |
| `parchment` | a well-made magazine. Warm cream paper, serif headlines at a whisper, ink-black buttons | [Cursor](https://styles.refero.design/style/4e3b4717-84c8-4599-baaf-a343c3d619b6), [Intercom](https://styles.refero.design/style/12255b63-e506-4bc1-a4cd-d05487de32f3), [ElevenLabs](https://styles.refero.design/style/031056ff-7af1-46db-8daa-115f731c5d26) |
| `moss` | confident and loud. Deep forest ink, lime voltage, heavy blocky headlines, pill buttons | [Wise](https://styles.refero.design/style/367c0c6e-73a7-441c-a8ff-91d139ac60dc) |
| `velvet` | quiet luxury for builders. Pure black, big white serif, violet only in the details | [Resend](https://styles.refero.design/style/0d914ef0-fa84-4c60-a9aa-cef0b5eb6e5d) |

These borrow each system's *ideas*: its structure, restraint, and type rhythm. They're
not clones: no logos, no brand names, no proprietary fonts. Fonts are system stacks, so
there's nothing to download and nothing for the CSP to block.

## The token contract

Every theme defines all of these. `tests/check-themes.py` enforces both the list and
contrast (WCAG 4.5:1 for body text, muted text, headings, links, and button labels).

| Token | Used for |
|---|---|
| `--bg`, `--surface`, `--surface-2` | page, cards and alternate sections, inline code |
| `--border`, `--border-strong` | hairlines, ghost buttons |
| `--heading`, `--text`, `--text-muted` | type, from loudest to quietest |
| `--link` | links inside text; must pass 4.5:1 on `--bg` |
| `--accent`, `--accent-ink` | primary buttons and the text on them |
| `--focus` (optional) | keyboard focus ring; defaults to `--accent` |
| `--font-sans`, `--font-display`, `--font-mono` | body, headlines, labels and code |
| `--display-weight`, `--display-tracking` | how headlines carry themselves |
| `--radius`, `--radius-lg`, `--radius-button` | corners |
| `--shadow` | card elevation (`none` is a fine answer) |

## Make your own from Refero

[Refero Styles](https://styles.refero.design) catalogs design systems from real products,
each with colors, type scale, spacing, and a DESIGN.md of do's and don'ts.

```sh
scripts/local/refero-css.py list                      # styles on the Refero home page
scripts/local/refero-css.py css <style-url> > /tmp/ref.css   # its CSS variables
scripts/local/refero-css.py md  <style-url>           # the full DESIGN.md, for the rules
```

Then write `themes/<yours>.css` by **mapping** its variables onto the contract above.
That mapping is the design decision: which of its neutrals becomes `--bg`, which accent
is reserved for `--accent`. Check it and use it:

```sh
python3 tests/check-themes.py themes/yours.css
scripts/local/new-site.sh --theme themes/yours.css      # new site
cp themes/yours.css "$SITE_DIR/src/styles/theme.css"     # existing site
```

When a brand's accent is too light for small text on its background (common with
oranges and limes), keep it for buttons and derive a darker `--link` from the same hue.
`parchment.css` does exactly this, and the checker will tell you when you need to.

With a paid Refero plan, the [Refero MCP](https://doc.refero.design/mcp/getting-started)
lets the `link` agent search screens and flows too. The script needs no account.
