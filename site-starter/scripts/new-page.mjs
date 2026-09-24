// Add a page:  npm run new:page -- "Title" [--description "..."] [--label "Nav text"] [--no-nav]
//
// Writes src/pages/<title-as-a-file-name>.astro using the site's layout and
// adds it to the header nav in src/site.json (before the button, if there is
// one). Refuses to overwrite a page, and refuses names the server already
// uses (/healthz, /assets/, /blog/ ...).
import { existsSync, readdirSync, writeFileSync } from 'node:fs';
import { at, die, oneLine, parse, readSite, rel, slugify, writeSite } from './lib.mjs';

const USAGE = 'npm run new:page -- "Title" [--description "One sentence."] [--label "Nav text"] [--no-nav]';
const DESCRIPTION_TODO = 'TODO: one sentence about this page, for search results and link previews.';
// Paths the site or the server already answer. A page there would be hidden
// (healthz is answered by nginx itself), cached for a year (assets), or clash.
const RESERVED = ['index', '404', 'blog', 'rss', 'robots', 'healthz', 'assets', 'favicon', 'sitemap'];

const { values, positionals } = parse(
  { description: { type: 'string' }, label: { type: 'string' }, 'no-nav': { type: 'boolean' }, slug: { type: 'string' } },
  USAGE,
);
if (positionals.length !== 1) die(`give the title once, in quotes. Usage: ${USAGE}`);
const title = oneLine('title', positionals[0], 70);
const description = values.description === undefined ? DESCRIPTION_TODO : oneLine('description', values.description, 160);
const label = values['no-nav'] ? '' : oneLine('nav label', values.label ?? title, 30);

const slug = values.slug ?? slugify(title);
if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) {
  die(values.slug !== undefined ? '--slug: lowercase letters, digits and single dashes only' : 'the title has no letters or digits to make a file name from; add --slug my-page');
}
if (RESERVED.includes(slug) || slug.startsWith('sitemap')) {
  die(`/${slug}/ is already used by the site or the server; choose another title or pass --slug`);
}
const taken = readdirSync(at('src/pages')).find((name) => name === slug || name.startsWith(`${slug}.`));
if (taken) die(`src/pages/${taken} already exists; choose another title or pass --slug`);

const file = at('src/pages', `${slug}.astro`);
const page = `---
import Base from '../layouts/Base.astro';
import site from '../site.json';

const title = ${JSON.stringify(title)};
const description = ${JSON.stringify(description)};
---
<Base title={\`\${title} | \${site.title}\`} description={description}>
  <section class="section">
    <div class="wrap narrow prose">
      <h1>{title}</h1>
      <p>Write here.</p>
    </div>
  </section>
</Base>
`;
writeFileSync(file, page, { flag: 'wx' });

let where = 'not in the nav';
if (!values['no-nav']) {
  const site = readSite();
  if (!Array.isArray(site.nav)) die('src/site.json has no "nav" list; the page was created but not linked');
  const href = `/${slug}/`;
  if (!site.nav.some((item) => item.href === href)) {
    const button = site.nav.findIndex((item) => item.button);
    site.nav.splice(button < 0 ? site.nav.length : button, 0, { label, href });
    writeSite(site);
  }
  where = `in the nav as ${JSON.stringify(label)}`;
}
const todo = description === DESCRIPTION_TODO ? '; replace its TODO description before you deploy' : '';
console.log(`${rel(file)} (${where})${todo}`);
