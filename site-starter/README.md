# {{DOMAIN}}

Your website. Astro turns these files into plain web pages, nginx serves them from your
server, and a Cloudflare tunnel carries them to the internet. Ship with `./scripts/local/deploy.sh`
from the playbook folder, after you commit.

```sh
npm install      # once
npm run dev      # preview at http://localhost:4322; it reloads as you edit
```

## Write a post

```sh
npm run new:post -- "What I learned building a shed"
```

That makes `src/content/posts/what-i-learned-building-a-shed.md`, marked as a draft. Write
under the second `---` line, fill in `description`, then set `draft: false` to publish.
Drafts show up in `npm run dev` and never on the live site. The example post explains
every setting; delete it once you have your own.

## Add a page

```sh
npm run new:page -- "About me"
```

That makes `src/pages/about-me.astro` and adds it to the header (`--no-nav` leaves it out).

## Change the title or description

```sh
npm run set:meta -- --title "Sam's Bakery" --description "Sourdough, baked on Saturday mornings."
```

Also `--author "Sam"` and `--image /images/card.png`, the picture shown when someone
shares a link (1200 by 630 pixels works everywhere). The marker sentence on the home page
stays put, because the live checks look for it. To change it, change `SITE_MARKER` in
`playbook.env` and `marker` in `src/site.json` together.

## Pictures

- **In pages and posts:** put them in `src/assets/`. From a post, write
  `![what it shows](../../assets/photo.jpg)`; in a page, use Astro's `<Image>`. They get
  resized, and renamed whenever they change, so nobody sees an old copy.
- **In `public/`:** only files that need a fixed address, like the share picture and the
  favicon. Replacing one there can keep showing the old copy for hours, so give a
  replacement a new file name.

## What the checks mean

`npm run build && npm run check` runs the same checks the server does. The build refuses
a post with a bad setting and names the file. Then `check` reads the finished site:

- `FAIL` stops the deploy: a broken link, a missing title or description, an image with
  no alt text, an inline script, anything from a host the security policy in `nginx.conf`
  blocks, or the marker missing from the home page. Each line names the page.
- `WARN` is advice and never stops anything: long titles, big images, no share picture.

## What GitHub does for you

- **site**: builds every push and pull request exactly as the server does; red means it would fail there too.
- **uptime**: checks the live site every 6 hours, opens a `site-down` issue when it
  fails and closes it when the site is back. GitHub pauses it after 60 days without a
  commit; any commit turns it back on.
- **Dependabot**: a few update pull requests a month. Merge them when **site** is green.

## Where things are

```
src/site.json           title, description, marker, address, header links
src/pages/              one file per page; index.astro is the home page
src/content/posts/      blog posts, one markdown file each
src/layouts/Base.astro  what every page shares: head tags, header, footer
src/styles/theme.css    colors and fonts
public/                 files served as they are: favicon, share picture
nginx.conf, Dockerfile  how the server serves the site, including its security policy
```
