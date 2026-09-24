// Post-build gate. Runs locally in deploy.sh AND inside the Docker build, so a
// broken site can never become the running image. Run it from the site's
// folder (it reads dist/, src/site.json, nginx.conf and public/ from there).
//
// FAIL (one line per problem, exit 1):
//   files    index, 404, sitemap, robots.txt with a Sitemap: line, and rss.xml
//            (well-formed) whenever a post is published
//   links    every local link, asset and og:image exists in dist/
//   leftover no unrendered template placeholder, no TODO title or description
//   csp      no inline <script>, on*= handler or javascript: link; every
//            outside script, style, image, font, frame, form and fetch host is
//            allowed by the CSP in nginx.conf; nothing loads over http://
//   seo      <title>, meta description, og:title, og:description, og:url,
//            a canonical link on the url in src/site.json, <html lang>,
//            exactly one <h1>
//   a11y     every <img> has alt (alt="" is right for decoration)
//   deploy   the build id is baked in, and the home page has the marker
//   svg      every .svg has the SVG xmlns and no "--" inside a comment
//   size     dist/ stays under the size budget
// WARN (printed, never fails): long or repeated titles and descriptions,
//   images over 300 KB, <img> without width and height, images in public/,
//   skipped heading levels, links with no text, no og:image, http:// links.
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join, dirname, resolve, relative, sep } from 'node:path';

const dist = resolve('dist');
const BUDGET_BYTES = 5 * 1024 * 1024;
const BIG_IMAGE_BYTES = 300 * 1024;
const IMAGE = /\.(png|jpe?g|gif|webp|avif|svg|ico|bmp|tiff?)$/i;
const errors = new Set();
const fail = (msg) => errors.add(msg);
const warnings = new Map();
const warn = (rule, item) => warnings.set(rule, [...(warnings.get(rule) ?? []), item]);

if (!existsSync(dist)) {
  console.error('FAIL dist/ does not exist. Run the build first.');
  process.exit(1);
}

const walk = (dir) =>
  readdirSync(dir).sort().flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
const files = walk(dist);
const html = files.filter((f) => f.endsWith('.html'));
const relOf = (f) => '/' + relative(dist, f).split(sep).join('/');

// ── Site data and the CSP ─────────────────────────────────────────────────────
let site = {};
try {
  site = JSON.parse(readFileSync(resolve('src/site.json'), 'utf8'));
} catch (e) {
  fail(`src/site.json: ${e.code === 'ENOENT' ? 'missing' : `not valid JSON (${e.message})`}`);
}
let origin = null;
try {
  const u = new URL(site.url);
  if (u.protocol === 'https:') origin = u.origin;
} catch {}
if (!origin) fail('src/site.json: "url" must be the site\'s https:// address, like https://example.com');

const csp = readCsp(resolve('nginx.conf'));
function readCsp(file) {
  if (!existsSync(file)) return fail('nginx.conf is missing, so the CSP it sends cannot be checked'), null;
  const conf = readFileSync(file, 'utf8').replace(/^\s*#.*$/gm, '');
  const m = conf.match(/add_header\s+Content-Security-Policy\s+(["'])(.*?)\1/i);
  if (!m) return fail('nginx.conf sends no Content-Security-Policy header'), null;
  const policy = {};
  for (const part of m[2].split(';')) {
    const [name, ...sources] = part.trim().split(/\s+/);
    if (name) policy[name.toLowerCase()] = sources.map((s) => s.toLowerCase());
  }
  return policy;
}
// A directive falls back to the next one in its chain when nginx.conf leaves it out.
const CHAIN = {
  'script-src-elem': ['script-src-elem', 'script-src', 'default-src'],
  'style-src-elem': ['style-src-elem', 'style-src', 'default-src'],
  'frame-src': ['frame-src', 'child-src', 'default-src'],
  'form-action': ['form-action'],
};
function sourceAllows(src, u) {
  if (src === "'self'") return u.origin === origin;
  if (src.startsWith("'")) return false; // 'none', nonces, hashes, 'unsafe-*'
  if (src === '*') return /^(https?|wss?):$/.test(u.protocol);
  if (/^[a-z][a-z0-9+.-]*:$/.test(src)) return u.protocol === src || (src === 'http:' && u.protocol === 'https:');
  const m = src.match(/^(?:([a-z][a-z0-9+.-]*):\/\/)?(\*\.)?([^/:]+)(?::(\d+|\*))?(\/.*)?$/);
  if (!m) return false;
  const [, scheme, wild, host, port, path] = m;
  const schemes = scheme ? (scheme === 'http' ? ['http:', 'https:'] : [`${scheme}:`]) : ['https:', 'wss:'];
  if (!schemes.includes(u.protocol)) return false;
  if (host !== '*' && !(wild ? u.hostname.endsWith(`.${host}`) : u.hostname === host)) return false;
  if (port !== '*' && (u.port || '') !== (port || '')) return false;
  if (path) return path.endsWith('/') ? u.pathname.startsWith(path) : u.pathname === path;
  return true;
}
function checkCsp(rel, url, directive, what) {
  if (!csp) return;
  const full = url.startsWith('//') ? `https:${url}` : url;
  if (!/^(https?|wss?|data|blob):/i.test(full)) return; // relative: this site
  let u;
  try { u = new URL(full); } catch { return; }
  const name = (CHAIN[directive] ?? [directive, 'default-src']).find((d) => csp[d]);
  if (!name || csp[name].some((s) => sourceAllows(s, u))) return;
  const from = /^(data|blob):$/.test(u.protocol) ? `a ${u.protocol} URL` : u.host;
  fail(`${rel}: ${what} ${from} is blocked by the CSP (${name} in nginx.conf); add the host there or serve the file from this site`);
}

// ── HTML, read with regexes that respect quotes ───────────────────────────────
// Astro leaves < and > unescaped inside attribute values, so a tag ends at the
// first > that is OUTSIDE quotes.
const TAG = /<([a-zA-Z][a-zA-Z0-9:-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*\/?>/g;
const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
const decode = (s) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) => {
    if (e[0] !== '#') return ENT[e.toLowerCase()] ?? m;
    try { return String.fromCodePoint(e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : Number(e.slice(1))); } catch { return m; }
  });
function parseAttrs(s) {
  const attrs = {};
  for (const m of s.matchAll(/([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
    attrs[m[1].toLowerCase()] = decode(m[2] ?? m[3] ?? m[4] ?? '');
  }
  return attrs;
}
function parsePage(raw) {
  const noComments = raw.replace(/<!--[\s\S]*?-->/g, '');
  const scripts = [...noComments.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)].map((m) => ({ attrs: parseAttrs(m[1]), body: m[2] }));
  const styles = [...noComments.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi)].map((m) => m[1]);
  // Blank script and style bodies so a URL inside JSON-LD isn't read as a tag.
  const markup = noComments.replace(/(<(script|style)\b[^>]*>)[\s\S]*?(<\/\2\s*>)/gi, '$1$3');
  const elements = [...markup.matchAll(TAG)].map((m) => ({
    name: m[1].toLowerCase(), attrs: parseAttrs(m[2] ?? ''), start: m.index, end: m.index + m[0].length,
  }));
  const headEnd = markup.search(/<\/head\s*>/i);
  const head = headEnd < 0 ? '' : markup.slice(0, headEnd);
  return { markup, elements, head, headEls: elements.filter((e) => e.start < headEnd), scripts, styles };
}
const meta = (page, key, value) => page.headEls.find((e) => e.name === 'meta' && e.attrs[key]?.toLowerCase() === value)?.attrs.content;
const rels = (el) => (el.attrs.rel ?? '').toLowerCase().split(/\s+/);

// Which CSP directive governs each attribute that loads something.
const PRELOAD = { script: 'script-src-elem', style: 'style-src-elem', font: 'font-src', image: 'img-src', fetch: 'connect-src' };
function loads(el) {
  const { name, attrs } = el;
  if (name === 'script') return [['src', 'script-src-elem', 'script from']];
  if (name === 'link') {
    const r = rels(el);
    if (r.includes('stylesheet')) return [['href', 'style-src-elem', 'stylesheet from']];
    if (r.some((x) => x === 'icon' || x === 'apple-touch-icon' || x === 'mask-icon')) return [['href', 'img-src', 'icon from']];
    if (r.includes('manifest')) return [['href', 'manifest-src', 'manifest from']];
    if (r.includes('modulepreload')) return [['href', 'script-src-elem', 'script from']];
    if (r.includes('preload') && PRELOAD[attrs.as]) return [['href', PRELOAD[attrs.as], `${attrs.as} from`]];
    return [];
  }
  const table = {
    img: [['src', 'img-src', 'image from'], ['srcset', 'img-src', 'image from']],
    source: [['srcset', 'img-src', 'image from'], ['src', 'media-src', 'media from']],
    video: [['src', 'media-src', 'video from'], ['poster', 'img-src', 'image from']],
    audio: [['src', 'media-src', 'audio from']],
    track: [['src', 'media-src', 'captions from']],
    iframe: [['src', 'frame-src', 'iframe of']],
    embed: [['src', 'object-src', 'embed from']],
    object: [['data', 'object-src', 'object from']],
    form: [['action', 'form-action', 'form posting to']],
    button: [['formaction', 'form-action', 'form posting to']],
    input: attrs.type?.toLowerCase() === 'image' ? [['src', 'img-src', 'image from']] : [],
  };
  return table[name] ?? [];
}
const urlsOf = (value, attr) =>
  attr === 'srcset' ? value.split(',').map((c) => c.trim().split(/\s+/)[0]).filter(Boolean) : [value.trim()];

function localExists(url, fromFile) {
  let path = url.split(/[?#]/)[0];
  if (!path) return true;
  try { path = decodeURIComponent(path); } catch {}
  const target = join(path.startsWith('/') ? dist : dirname(fromFile), path);
  return existsSync(target) && (statSync(target).isFile() || existsSync(join(target, 'index.html')));
}
const external = (url) => /^([a-z][a-z0-9+.-]*:|\/\/)/i.test(url);

function checkCss(rel, css, fromFile) {
  const fonts = [...css.matchAll(/@font-face\s*\{[^}]*\}/gi)].map((m) => m[0]).join('\n');
  const imports = [...css.matchAll(/@import\s+(?:url\(\s*)?(["']?)([^"')\s;]+)\1/gi)].map((m) => m[2]);
  const rest = css.replace(/@font-face\s*\{[^}]*\}/gi, '').replace(/@import[^;]*;/gi, '');
  const urls = (s) => [...s.matchAll(/url\(\s*(["']?)([^"')]+?)\1\s*\)/gi)].map((m) => m[2].trim());
  const found = [
    ...urls(fonts).map((u) => [u, 'font-src', 'font from']),
    ...imports.map((u) => [u, 'style-src-elem', 'stylesheet from']),
    ...urls(rest).map((u) => [u, 'img-src', 'image from']),
  ];
  for (const [url, directive, what] of found) {
    if (/^http:/i.test(url)) fail(`${rel}: CSS loads ${url} over http://, which browsers block on an https page`);
    else if (external(url)) checkCsp(rel, url, directive, what);
    else if (fromFile && !localExists(url, fromFile)) fail(`${rel}: broken link ${url}`);
  }
}

// ── Required files ────────────────────────────────────────────────────────────
for (const must of ['index.html', '404.html', 'sitemap-index.xml']) {
  if (!existsSync(join(dist, must))) fail(`missing ${must}`);
}
const robots = join(dist, 'robots.txt');
if (!existsSync(robots)) fail('missing robots.txt');
else if (!/^\s*sitemap:\s*https?:\/\/\S+/im.test(readFileSync(robots, 'utf8'))) fail('robots.txt has no Sitemap: line');

// Published posts, straight from the source, so a feed that stopped being
// built is caught even though nothing links to it by name.
const postsDir = resolve('src/content/posts');
const postFiles = existsSync(postsDir) ? walk(postsDir).filter((f) => f.endsWith('.md')) : [];
const frontmatter = postFiles.map((f) => (readFileSync(f, 'utf8').match(/^---\r?\n([\s\S]*?)\r?\n---/) ?? [])[1] ?? '');
const published = frontmatter.filter((fm) => !/^draft:\s*true\s*$/m.test(fm)).length;
const rss = join(dist, 'rss.xml');
if (!existsSync(rss)) {
  if (published) fail(`missing rss.xml, but ${published} post(s) are published`);
} else {
  const problem = xmlProblem(readFileSync(rss, 'utf8'));
  if (problem) fail(`rss.xml is not well-formed XML: ${problem}`);
}

// ── Every page ────────────────────────────────────────────────────────────────
const want = process.env.PUBLIC_BUILD_ID;
const titles = new Map();
const descriptions = new Map();
for (const file of html) {
  const rel = relOf(file);
  const raw = readFileSync(file, 'utf8');
  const page = parsePage(raw);

  const leftover = raw.match(/\{\{[A-Z_]+\}\}/);
  if (leftover) fail(`${rel}: unrendered placeholder ${leftover[0]}`);

  const build = raw.match(/<meta name="build" content="build:([^"]+)"/);
  if (!build) fail(`${rel}: no build id meta tag`);
  else if (want && build[1] !== want) fail(`${rel}: build id ${build[1]}, expected ${want} (stale dist/?)`);

  for (const { attrs, body } of page.scripts) {
    const type = attrs.type?.toLowerCase() ?? '';
    if (/^application\/(ld\+)?json$/.test(type)) {
      if (type === 'application/ld+json') {
        try { JSON.parse(body); } catch (e) { fail(`${rel}: JSON-LD is not valid JSON (${e.message})`); }
      }
    } else if (!('src' in attrs) && body.trim()) {
      fail(`${rel}: inline <script> would be blocked by the CSP in production`);
    }
  }
  for (const css of page.styles) checkCss(rel, css, file);

  // Head: what search engines and link previews read.
  const titleMatch = page.head.match(/<title\b[^>]*>([\s\S]*?)<\/title\s*>/i);
  const title = decode(titleMatch?.[1] ?? '').trim();
  const description = (meta(page, 'name', 'description') ?? '').trim();
  const noindex = /noindex/i.test(meta(page, 'name', 'robots') ?? '');
  if (!title) fail(`${rel}: missing or empty <title>`);
  if (!description) fail(`${rel}: missing meta description`);
  if (/^TODO\b/i.test(title)) fail(`${rel}: the <title> is still a TODO placeholder`);
  if (/^TODO\b/i.test(description)) fail(`${rel}: the meta description is still a TODO placeholder`);
  for (const prop of ['og:title', 'og:description', 'og:url']) {
    if (!meta(page, 'property', prop)?.trim()) fail(`${rel}: missing ${prop}`);
  }
  const canonical = page.headEls.find((e) => e.name === 'link' && rels(e).includes('canonical'))?.attrs.href;
  if (!canonical) fail(`${rel}: missing <link rel="canonical">`);
  else if (origin) {
    let on = false;
    try { on = new URL(canonical).origin === origin; } catch {}
    if (!on) fail(`${rel}: canonical ${canonical} is not on ${origin} (the url in src/site.json)`);
  }
  const ogImage = meta(page, 'property', 'og:image');
  if (ogImage && origin) {
    try {
      const u = new URL(ogImage);
      if (u.origin === origin && !localExists(u.pathname, file)) fail(`${rel}: og:image ${u.pathname} is not in dist/ (put the file in public${u.pathname})`);
    } catch { fail(`${rel}: og:image ${ogImage} is not a full https:// address`); }
  }
  if (!noindex) {
    if (title.length > 60) warn('title over 60 characters (search results cut it off)', `${rel} (${title.length})`);
    if (description && (description.length < 50 || description.length > 160)) warn('meta description outside 50 to 160 characters', `${rel} (${description.length})`);
    if (!ogImage) warn('no og:image, so shared links show no picture (set "image" in src/site.json)', rel);
    if (title) titles.set(title, [...(titles.get(title) ?? []), rel]);
    if (description) descriptions.set(description, [...(descriptions.get(description) ?? []), rel]);
  }

  const htmlEl = page.elements.find((e) => e.name === 'html');
  if (!htmlEl?.attrs.lang?.trim()) fail(`${rel}: <html> has no lang attribute (screen readers need it to pick a voice)`);
  const h1s = (page.markup.match(/<h1\b[^>]*>/gi) ?? []).length;
  if (h1s !== 1) fail(`${rel}: ${h1s} <h1> headings; a page needs exactly one`);
  let prev = 0;
  for (const m of page.markup.matchAll(/<h([1-6])\b[^>]*>/gi)) {
    const level = Number(m[1]);
    if (prev && level > prev + 1) warn('heading level skipped (screen readers use headings as a table of contents)', `${rel} h${prev} then h${level}`);
    prev = level;
  }

  for (const el of page.elements) {
    const { name, attrs } = el;
    for (const attr of Object.keys(attrs)) {
      if (/^on[a-z]+$/.test(attr)) fail(`${rel}: inline ${attr}= handler on <${name}> would be blocked by the CSP in production`);
    }
    if (name === 'img') {
      if (!('alt' in attrs)) fail(`${rel}: <img src="${attrs.src ?? ''}"> has no alt attribute (describe it, or alt="" for decoration)`);
      if (!attrs.width || !attrs.height) warn('<img> without width and height (the page jumps while it loads)', `${rel} ${attrs.src ?? ''}`);
    }
    if (attrs.style) checkCss(rel, attrs.style, null);
    for (const attr of ['href', 'src', 'srcset', 'action', 'formaction', 'poster', 'data']) {
      if (!(attr in attrs)) continue;
      for (const url of urlsOf(attrs[attr], attr)) {
        if (/^javascript:/i.test(url)) fail(`${rel}: javascript: URL on <${name}> would be blocked by the CSP in production`);
        else if (/^http:\/\//i.test(url)) {
          if ((name === 'a' || name === 'area') && attr === 'href') warn('link to an http:// page (use https:// if the site has it)', `${rel} ${url}`);
          else fail(`${rel}: <${name} ${attr}="${url}"> loads over http://, which browsers block on an https page`);
        } else if (!external(url) && (attr === 'href' || attr === 'src' || attr === 'srcset') && !localExists(url, file)) {
          fail(`${rel}: broken link ${url}`);
        }
      }
    }
    for (const [attr, directive, what] of loads(el)) {
      if (attrs[attr]) for (const url of urlsOf(attrs[attr], attr)) checkCsp(rel, url, directive, what);
    }
    if (name === 'a' && attrs.href !== undefined) {
      const closeTag = /<\/a\s*>/gi;
      closeTag.lastIndex = el.end;
      const close = closeTag.exec(page.markup)?.index ?? el.end;
      const inner = page.markup.slice(el.end, close);
      const text = decode(inner.replace(TAG, ' ').replace(/<\/[^>]*>/g, ' ')).trim();
      const named = page.elements.some((e) => e.start >= el.end && e.start < close && ((e.name === 'img' && e.attrs.alt?.trim()) || e.attrs['aria-label']?.trim()));
      if (!text && !named && !attrs['aria-label']?.trim() && !attrs['aria-labelledby'] && !attrs.title?.trim()) {
        warn('link with no text and no aria-label (screen readers just say "link")', `${rel} ${attrs.href}`);
      }
    }
  }
}
for (const [value, pages] of titles) if (pages.length > 1) warn('same <title> on more than one page', `"${value}" on ${pages.join(' ')}`);
for (const [value, pages] of descriptions) if (pages.length > 1) warn('same meta description on more than one page', pages.join(' '));

const home = join(dist, 'index.html');
if (!site.marker) fail('src/site.json has no "marker" (the live checks look for it on the home page)');
else if (existsSync(home) && !readFileSync(home, 'utf8').includes(site.marker)) {
  fail(`index.html does not contain the marker "${site.marker}" from src/site.json (the live checks look for it)`);
}

// ── Every other file ──────────────────────────────────────────────────────────
for (const file of files) {
  const rel = relOf(file);
  const size = statSync(file).size;
  if (IMAGE.test(file) && size > BIG_IMAGE_BYTES) warn('image over 300 KB (slow on phones; make it smaller)', `${rel} (${Math.round(size / 1024)} KB)`);
  if (file.endsWith('.css')) checkCss(rel, readFileSync(file, 'utf8'), file);
  if (file.endsWith('.js') || file.endsWith('.mjs')) {
    const js = readFileSync(file, 'utf8');
    for (const m of js.matchAll(/\b(?:fetch|EventSource|WebSocket|sendBeacon)\s*\(\s*(["'`])((?:https?|wss?):\/\/[^"'`\s]+)\1/g)) {
      checkCsp(rel, m[2], 'connect-src', 'fetch to');
    }
  }
  if (file.endsWith('.svg')) {
    const svg = readFileSync(file, 'utf8');
    const root = [...svg.matchAll(TAG)].find((m) => m[1].toLowerCase() === 'svg');
    if (!root || parseAttrs(root[2] ?? '').xmlns !== 'http://www.w3.org/2000/svg') {
      fail(`${rel}: no xmlns="http://www.w3.org/2000/svg" on <svg>, so browsers won't show it as an image`);
    }
    if ([...svg.matchAll(/<!--([\s\S]*?)-->/g)].some((m) => m[1].includes('--') || m[1].endsWith('-'))) {
      fail(`${rel}: "--" inside a comment makes the SVG invalid, so browsers show nothing`);
    }
  }
}

// Images in public/ keep their names forever, so after a replacement
// Cloudflare (and browsers) can keep serving the old copy. The share image in
// site.json and each post's share image have to live there; the rest needn't.
const pub = resolve('public');
if (existsSync(pub)) {
  const shareImages = new Set([site.image, ...frontmatter.map((fm) => fm.match(/^image:\s*["']?([^"'\s]+)/m)?.[1])]);
  for (const file of walk(pub)) {
    const path = '/' + relative(pub, file).split(sep).join('/');
    if (IMAGE.test(file) && !/^\/favicon\./i.test(path) && !shareImages.has(path)) {
      warn('image in public/: after you replace it, visitors can keep getting the old copy (use src/assets and astro:assets, or give the new file a new name)', `public${path}`);
    }
  }
}

const total = files.reduce((n, f) => n + statSync(f).size, 0);
if (total > BUDGET_BYTES) fail(`dist/ is ${(total / 1048576).toFixed(1)} MB, budget ${BUDGET_BYTES / 1048576} MB`);

// Just enough of XML's rules to catch what breaks a feed: unescaped & and <,
// entities XML doesn't define (&nbsp;), "]]>" in text, and unbalanced tags.
function xmlProblem(text) {
  const re = /<!--([\s\S]*?)-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<\/([^\s>]+)\s*>|<([A-Za-z_][\w.:-]*)((?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|(<)|(&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);))|(\]\]>)/g;
  const badValue = /<|&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/;
  const stack = [];
  let roots = 0;
  for (const [, comment, close, open, attrs, selfClose, lt, amp, cdataEnd] of text.matchAll(re)) {
    if (comment !== undefined && (comment.includes('--') || comment.endsWith('-'))) return '"--" inside a comment';
    if (close && stack.pop() !== close) return `</${close}> does not match the open tag`;
    if (open) {
      if (!stack.length && ++roots > 1) return 'more than one root element';
      if (badValue.test(attrs)) return `a raw < or & in an attribute of <${open}>`;
      if (!selfClose) stack.push(open);
    }
    if (lt) return 'a < that does not start a tag (write &lt;)';
    if (amp) return 'a bare & or an entity XML does not define (write &amp;)';
    if (cdataEnd) return '"]]>" in text (write ]]&gt;)';
  }
  if (stack.length) return `<${stack.at(-1)}> is never closed`;
  return roots ? null : 'no root element';
}

for (const [rule, items] of warnings) {
  const shown = items.slice(0, 5).join(', ');
  console.log(`WARN ${rule}: ${shown}${items.length > 5 ? `, and ${items.length - 5} more` : ''}`);
}
if (errors.size) {
  for (const e of errors) console.error(`FAIL ${e}`);
  process.exit(1);
}
const warned = warnings.size ? ` (${warnings.size} warning${warnings.size > 1 ? 's' : ''})` : '';
console.log(`check-dist OK: ${html.length} pages, ${files.length} files, ${(total / 1024).toFixed(0)} KB${warned}`);
