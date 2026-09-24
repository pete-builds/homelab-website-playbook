// Tests for the site starter's own gates: scripts/check-dist.mjs, the content
// scripts (new:post, new:page, set:meta) and the helpers they share.
// Plain Node 20+, nothing to install:
//
//   node --test tests/test-check-dist.mjs      (or: node tests/test-check-dist.mjs)
//
// tests/fixtures/check-dist/good/ is a small site root laid out like a real one
// after `npm run build` (dist/, src/site.json, src/content/posts/, public/,
// nginx.conf). Its HTML copies what Astro really emits: data-astro-cid
// attributes, a raw < inside a quoted attribute, an inline SVG with its own
// <title>, a commented-out tag. check-dist must pass it with no WARN at all,
// which is what makes every case below meaningful: each copies the fixture,
// breaks ONE thing, and asserts the exact FAIL (or WARN) line it produces and
// that nothing else failed.
import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync, appendFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const starter = join(repo, 'site-starter');
const GOOD = join(repo, 'tests/fixtures/check-dist/good');
const CHECK = join(starter, 'scripts/check-dist.mjs');
const I = 'dist/index.html';
const BLOG = 'dist/blog/index.html';
const POST = 'dist/blog/hello/index.html';
const PAGES = [I, 'dist/404.html', BLOG, POST];

const temp = () => mkdtempSync(join(tmpdir(), 'site-starter-test-'));
function withCopy(fn) {
  const dir = temp();
  cpSync(GOOD, dir, { recursive: true });
  try { return fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}
function edit(dir, file, from, to) {
  const path = join(dir, file);
  const before = readFileSync(path, 'utf8');
  const after = before.replace(from, to);
  assert.notEqual(after, before, `fixture edit changed nothing in ${file}: ${from}`);
  writeFileSync(path, after);
}
const addToHead = (html) => (dir) => edit(dir, I, '</head>', `${html}</head>`);
const addToBody = (html) => (dir) => edit(dir, I, '</main>', `${html}</main>`);
function check(dir, env = {}) {
  const e = { ...process.env, ...env };
  if (!('PUBLIC_BUILD_ID' in env)) delete e.PUBLIC_BUILD_ID;
  const r = spawnSync(process.execPath, [CHECK], { cwd: dir, encoding: 'utf8', env: e });
  const out = `${r.stdout}${r.stderr}`;
  const lines = out.split('\n').filter(Boolean);
  return { code: r.status, out, fails: lines.filter((l) => l.startsWith('FAIL ')), warns: lines.filter((l) => l.startsWith('WARN ')) };
}

describe('check-dist: the known-good fixture', () => {
  test('passes with exit 0, no FAIL and no WARN', () => withCopy((dir) => {
    const r = check(dir);
    assert.equal(r.code, 0, r.out);
    assert.deepEqual(r.fails, []);
    assert.deepEqual(r.warns, [], 'the good fixture must be warning-free, or the WARN tests prove nothing');
    assert.match(r.out, /^check-dist OK: 4 pages, \d+ files, \d+ KB$/m);
  }));
  test('passes with the matching build id', () => withCopy((dir) => {
    assert.equal(check(dir, { PUBLIC_BUILD_ID: 'fixture' }).code, 0);
  }));
  test('a blog whose only post is a draft needs no rss.xml', () => withCopy((dir) => {
    edit(dir, 'src/content/posts/hello.md', 'draft: false', 'draft: true');
    unlinkSync(join(dir, 'dist/rss.xml'));
    for (const page of PAGES) edit(dir, page, /<link rel="alternate" type="application\/rss\+xml" title="[^"]*" href="\/rss\.xml">/, '');
    edit(dir, BLOG, '<p><a href="/rss.xml">RSS feed</a></p>', '');
    const r = check(dir);
    assert.equal(r.code, 0, r.out);
  }));
  test('a wildcard CSP host allows subdomains but not the bare domain', () => withCopy((dir) => {
    edit(dir, 'nginx.conf', "img-src 'self' data:", "img-src 'self' data: https://*.example.net");
    addToBody('<img src="https://images.example.net/a.png" alt="a" width="1" height="1">')(dir);
    assert.equal(check(dir).code, 0);
    addToBody('<img src="https://example.net/a.png" alt="a" width="1" height="1">')(dir);
    assert.deepEqual(check(dir).fails, ['FAIL /index.html: image from example.net is blocked by the CSP (img-src in nginx.conf); add the host there or serve the file from this site']);
  }));
  test('the real site-starter/nginx.conf allows the Cloudflare beacon and blocks other hosts', () => withCopy((dir) => {
    cpSync(join(starter, 'nginx.conf'), join(dir, 'nginx.conf'));
    assert.equal(check(dir).code, 0, 'the starter CSP must parse and allow what the fixture loads');
    addToHead('<script src="https://cdn.evil.example/x.js"></script>')(dir);
    const r = check(dir);
    assert.equal(r.code, 1);
    assert.match(r.fails.join('\n'), /script from cdn\.evil\.example is blocked by the CSP \(script-src in nginx\.conf\)/);
  }));
});

// [name, break one thing, the FAIL lines it must produce (substrings), env]
const FAILS = [
  ['empty <title>', (d) => edit(d, I, /<title>[^<]*<\/title>/, '<title> </title>'), ['/index.html: missing or empty <title>']],
  ['no meta description', (d) => edit(d, I, /<meta name="description"[^>]*>/, ''), ['/index.html: missing meta description']],
  ['no <h1>', (d) => edit(d, I, '<h1 data-astro-cid-j7pv25f6>Hello from the fixture</h1>', '<p>Hello from the fixture</p>'), ['/index.html: 0 <h1> headings; a page needs exactly one']],
  ['two <h1>, both with data-astro-cid attributes', (d) => edit(d, I, '<p>Intro.</p>', '<h1 data-astro-cid-j7pv25f6 class="x">Again</h1>'), ['/index.html: 2 <h1> headings; a page needs exactly one']],
  ['no og:title', (d) => edit(d, I, /<meta property="og:title"[^>]*>/, ''), ['/index.html: missing og:title']],
  ['no og:description', (d) => edit(d, I, /<meta property="og:description"[^>]*>/, ''), ['/index.html: missing og:description']],
  ['no og:url', (d) => edit(d, I, /<meta property="og:url"[^>]*>/, ''), ['/index.html: missing og:url']],
  ['no canonical', (d) => edit(d, I, /<link rel="canonical"[^>]*>/, ''), ['/index.html: missing <link rel="canonical">']],
  ['canonical on another site', (d) => edit(d, I, '<link rel="canonical" href="https://example.org/">', '<link rel="canonical" href="https://example.com/">'), ['/index.html: canonical https://example.com/ is not on https://example.org (the url in src/site.json)']],
  ['<img> without alt', (d) => edit(d, I, 'alt="A photo of the fixture" ', ''), ['/index.html: <img src="/assets/photo.abc123.png"> has no alt attribute']],
  ['<html> without lang', (d) => edit(d, I, '<html lang="en">', '<html>'), ['/index.html: <html> has no lang attribute']],
  ['http:// preconnect (mixed content)', addToHead('<link rel="preconnect" href="http://cdn.example.net">'), ['/index.html: <link href="http://cdn.example.net"> loads over http://']],
  ['http:// in srcset (mixed content, and off the CSP)', (d) => edit(d, I, '/assets/photo.abc123.png 2x', 'http://cdn.example.net/p.png 2x'),
    ['/index.html: <img srcset="http://cdn.example.net/p.png"> loads over http://', '/index.html: image from cdn.example.net is blocked by the CSP (img-src in nginx.conf)']],
  ['robots.txt missing', (d) => unlinkSync(join(d, 'dist/robots.txt')), ['missing robots.txt']],
  ['robots.txt without a Sitemap: line', (d) => writeFileSync(join(d, 'dist/robots.txt'), 'User-agent: *\nAllow: /\n'), ['robots.txt has no Sitemap: line']],
  ['home page without the marker', (d) => edit(d, 'src/site.json', 'Hello from the fixture', 'Hello from somewhere else'), ['index.html does not contain the marker "Hello from somewhere else" from src/site.json']],
  ['site.json without a marker', (d) => edit(d, 'src/site.json', '"marker": "Hello from the fixture"', '"marker": ""'), ['src/site.json has no "marker"']],
  ['site.json url not https', (d) => edit(d, 'src/site.json', '"https://example.org"', '"http://example.org"'), ['src/site.json: "url" must be the site\'s https:// address']],
  ['script from a host the CSP does not allow', addToHead('<script src="https://cdn.evil.example/x.js"></script>'), ['/index.html: script from cdn.evil.example is blocked by the CSP (script-src in nginx.conf)']],
  ['script from a data: URL', addToHead('<script src="data:text/javascript,alert(1)"></script>'), ['/index.html: script from a data: URL is blocked by the CSP (script-src in nginx.conf)']],
  ['stylesheet from Google Fonts', addToHead('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">'), ['/index.html: stylesheet from fonts.googleapis.com is blocked by the CSP (style-src in nginx.conf)']],
  ['image from another host', addToBody('<img src="https://images.example.net/a.png" alt="a" width="1" height="1">'), ['/index.html: image from images.example.net is blocked by the CSP (img-src in nginx.conf)']],
  ['iframe from another host', addToBody('<iframe src="https://www.youtube-nocookie.com/embed/x" title="video"></iframe>'), ['/index.html: iframe of www.youtube-nocookie.com is blocked by the CSP (default-src in nginx.conf)']],
  ['font from another host in CSS', (d) => appendFileSync(join(d, 'dist/assets/Base.abc123.css'), '@font-face{font-family:X;src:url(https://fonts.gstatic.com/x.woff2)}'), ['/assets/Base.abc123.css: font from fonts.gstatic.com is blocked by the CSP (default-src in nginx.conf)']],
  ['fetch to another host', (d) => appendFileSync(join(d, 'dist/assets/page.abc123.js'), 'fetch("https://api.example.net/v1");'), ['/assets/page.abc123.js: fetch to api.example.net is blocked by the CSP (connect-src in nginx.conf)']],
  ['form posting to another host', (d) => edit(d, I, '<form action="/"', '<form action="https://formspree.io/f/abc"'), ['/index.html: form posting to formspree.io is blocked by the CSP (form-action in nginx.conf)']],
  ['SVG without xmlns', (d) => edit(d, 'dist/favicon.svg', ' xmlns="http://www.w3.org/2000/svg"', ''), ['/favicon.svg: no xmlns="http://www.w3.org/2000/svg" on <svg>']],
  ['SVG with -- in a comment', (d) => edit(d, 'dist/favicon.svg', '<rect', '<!-- drawn -- by hand --><rect'), ['/favicon.svg: "--" inside a comment makes the SVG invalid']],
  ['rss.xml missing while a post is published', (d) => {
    unlinkSync(join(d, 'dist/rss.xml'));
    for (const page of PAGES) edit(d, page, /<link rel="alternate" type="application\/rss\+xml" title="[^"]*" href="\/rss\.xml">/, '');
    edit(d, BLOG, '<p><a href="/rss.xml">RSS feed</a></p>', '');
  }, ['missing rss.xml, but 1 post(s) are published']],
  ['rss.xml with a raw <b>&', (d) => edit(d, 'dist/rss.xml', '&lt;b&gt;&amp;', '<b>&'), ['rss.xml is not well-formed XML: a bare & or an entity XML does not define']],
  ['rss.xml with ]]> in text', (d) => edit(d, 'dist/rss.xml', 'CDATA ]]&gt;', 'CDATA ]]>'), ['rss.xml is not well-formed XML: "]]>" in text']],
  ['rss.xml with an unclosed tag', (d) => edit(d, 'dist/rss.xml', '</channel>', ''), ['rss.xml is not well-formed XML: </rss> does not match the open tag']],
  ['unrendered placeholder', (d) => edit(d, I, '<p>Intro.</p>', '<p>{{DOMAIN}}</p>'), ['/index.html: unrendered placeholder {{DOMAIN}}']],
  ['inline <script>', addToBody('<script>alert(1)</script>'), ['/index.html: inline <script> would be blocked by the CSP in production']],
  ['inline onclick= handler', (d) => edit(d, I, '<button type="submit">', '<button type="submit" onclick="go()">'), ['/index.html: inline onclick= handler on <button> would be blocked by the CSP']],
  ['javascript: link', addToBody('<a href="javascript:void(0)">Go</a>'), ['/index.html: javascript: URL on <a> would be blocked by the CSP']],
  ['invalid JSON-LD', (d) => edit(d, I, '"url":"https://example.org/"}</script>', '"url":}</script>'), ['/index.html: JSON-LD is not valid JSON']],
  ['no build id', (d) => edit(d, I, '<meta name="build" content="build:fixture">', ''), ['/index.html: no build id meta tag']],
  ['stale build id', () => {}, ['/404.html: build id fixture, expected abc123', '/blog/hello/index.html: build id fixture', '/blog/index.html: build id fixture', '/index.html: build id fixture'], { PUBLIC_BUILD_ID: 'abc123' }],
  ['broken local link', addToBody('<a href="/blog/missing/">Missing</a>'), ['/index.html: broken link /blog/missing/']],
  ['broken local url() in CSS', (d) => appendFileSync(join(d, 'dist/assets/Base.abc123.css'), 'main{background:url(/assets/gone.png)}'), ['/assets/Base.abc123.css: broken link /assets/gone.png']],
  ['og:image file missing', (d) => unlinkSync(join(d, 'dist/og.png')), ['/index.html: og:image /og.png is not in dist/', '/blog/index.html: og:image /og.png', '/blog/hello/index.html: og:image /og.png']],
  ['TODO description shipped', (d) => edit(d, BLOG, 'content="Notes and posts from Fixture Site, newest first. Follow along with the RSS feed."', 'content="TODO: one sentence about this page, for search results and link previews."'), ['/blog/index.html: the meta description is still a TODO placeholder']],
  ['missing 404.html', (d) => unlinkSync(join(d, 'dist/404.html')), ['missing 404.html']],
  ['over the size budget', (d) => writeFileSync(join(d, 'dist/assets/big.bin'), Buffer.alloc(6 * 1024 * 1024)), ['dist/ is 6.0 MB, budget 5 MB']],
  ['nginx.conf missing', (d) => unlinkSync(join(d, 'nginx.conf')), ['nginx.conf is missing']],
  ['nginx.conf with its CSP only in a comment', (d) => edit(d, 'nginx.conf', /^\s*add_header Content-Security-Policy.*$/m, ''), ['nginx.conf sends no Content-Security-Policy header']],
];
describe('check-dist: each FAIL rule fails, with its own message', () => {
  for (const [name, mutate, expected, env] of FAILS) {
    test(name, () => withCopy((dir) => {
      mutate(dir);
      const r = check(dir, env);
      assert.equal(r.code, 1, `expected exit 1:\n${r.out}`);
      for (const want of expected) assert.ok(r.fails.some((l) => l.includes(want)), `expected a FAIL containing "${want}", got:\n${r.out}`);
      assert.equal(r.fails.length, expected.length, `expected exactly ${expected.length} FAIL line(s):\n${r.out}`);
    }));
  }
});

// [name, break one thing, WARN substrings]
const WARNS = [
  ['title over 60 characters', (d) => edit(d, I, '<title>Fixture Site: a good build</title>', '<title>Fixture Site: a good build with a title far longer than sixty characters</title>'), ['WARN title over 60 characters', '/index.html (72)']],
  ['same title on two pages', (d) => edit(d, BLOG, '<title>Blog | Fixture Site</title>', '<title>Fixture Site: a good build</title>'), ['WARN same <title> on more than one page', '/blog/index.html /index.html']],
  ['description under 50 characters', (d) => edit(d, BLOG, 'content="Notes and posts from Fixture Site, newest first. Follow along with the RSS feed."', 'content="Too short."'), ['WARN meta description outside 50 to 160 characters', '/blog/index.html (10)']],
  ['same description on two pages', (d) => edit(d, BLOG, 'content="Notes and posts from Fixture Site, newest first. Follow along with the RSS feed."', 'content="The known-good fixture that check-dist has to pass with no failures and no warnings."'), ['WARN same meta description on more than one page']],
  ['image over 300 KB', (d) => writeFileSync(join(d, 'dist/assets/huge.abc123.png'), Buffer.alloc(400 * 1024)), ['WARN image over 300 KB', '/assets/huge.abc123.png (400 KB)']],
  ['<img> without width and height', (d) => edit(d, I, '<img src="/assets/photo.abc123.png" alt="" width="4" height="3">', '<img src="/assets/photo.abc123.png" alt="">'), ['WARN <img> without width and height', '/index.html /assets/photo.abc123.png']],
  ['image in public/', (d) => cpSync(join(d, 'public/og.png'), join(d, 'public/photo.png')), ['WARN image in public/', 'public/photo.png']],
  ['skipped heading level', (d) => edit(d, POST, '<h3>Detail</h3>', '<h4>Detail</h4>'), ['WARN heading level skipped', '/blog/hello/index.html h2 then h4']],
  ['link with no text', addToBody('<a href="/blog/"><span class="icon"></span></a>'), ['WARN link with no text and no aria-label', '/index.html /blog/']],
  ['no og:image', (d) => edit(d, BLOG, /<meta property="og:image" [^>]*>/, ''), ['WARN no og:image', '/blog/index.html']],
  ['link to an http:// page', addToBody('<a href="http://old.example.net/">Old site</a>'), ['WARN link to an http:// page', '/index.html http://old.example.net/']],
];
describe('check-dist: each WARN rule warns and still exits 0', () => {
  for (const [name, mutate, expected] of WARNS) {
    test(name, () => withCopy((dir) => {
      mutate(dir);
      const r = check(dir);
      assert.equal(r.code, 0, `a WARN must never fail the build:\n${r.out}`);
      assert.equal(r.warns.length, 1, `expected exactly one WARN line:\n${r.out}`);
      for (const want of expected) assert.ok(r.warns[0].includes(want), `expected "${want}" in:\n${r.out}`);
      assert.match(r.out, /check-dist OK: .* \(1 warning\)$/m);
    }));
  }
});

// ── Content scripts ───────────────────────────────────────────────────────────
function siteCopy() {
  const dir = temp();
  for (const part of ['scripts', 'src', 'public', 'package.json']) cpSync(join(starter, part), join(dir, part), { recursive: true });
  return dir;
}
function run(dir, script, ...args) {
  const r = spawnSync(process.execPath, [join(dir, 'scripts', script), ...args], { cwd: dir, encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr, lines: r.stdout.split('\n').filter(Boolean) };
}
const read = (dir, file) => readFileSync(join(dir, file), 'utf8');
function refuses(r, pattern) {
  assert.equal(r.code, 1, `expected exit 1:\n${r.stdout}${r.stderr}`);
  const errs = r.stderr.split('\n').filter(Boolean);
  assert.equal(errs.length, 1, `expected a one-line reason:\n${r.stderr}`);
  assert.match(errs[0], /^ERROR: /);
  assert.match(errs[0], pattern);
}
const localToday = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};

describe('npm run new:post', () => {
  const title = 'Crème Brûlée: A "Love" Story, 50% off';
  test('slugs the title, dates it today, starts as a draft, YAML-safe', () => {
    const dir = siteCopy();
    try {
      const r = run(dir, 'new-post.mjs', title);
      assert.equal(r.code, 0, r.stderr);
      assert.equal(r.lines.length, 2);
      assert.equal(r.lines[0], 'src/content/posts/creme-brulee-a-love-story-50-off.md');
      assert.match(r.lines[1], /draft: false/);
      const text = read(dir, r.lines[0]);
      const fm = Object.fromEntries(text.split('\n---')[0].split('\n').slice(1).map((l) => [l.slice(0, l.indexOf(':')), l.slice(l.indexOf(':') + 2)]));
      // A JSON string is a YAML double-quoted scalar, so parsing it as JSON
      // proves YAML reads back exactly the title that went in.
      assert.equal(JSON.parse(fm.title), title);
      assert.equal(fm.date, localToday());
      assert.equal(fm.draft, 'true');
      assert.match(JSON.parse(fm.description), /^TODO/);
      assert.equal(text.split('\n').filter((l) => l === '---').length, 2);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('writes a given description, and refuses to overwrite', () => {
    const dir = siteCopy();
    try {
      assert.equal(run(dir, 'new-post.mjs', 'Twice', '--description', 'First: "one".').code, 0);
      const before = read(dir, 'src/content/posts/twice.md');
      assert.match(before, /^description: "First: \\"one\\"\."$/m);
      refuses(run(dir, 'new-post.mjs', 'Twice', '--description', 'Second.'), /already exists/);
      assert.equal(read(dir, 'src/content/posts/twice.md'), before);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('refuses bad input with one line each', () => {
    const dir = siteCopy();
    try {
      refuses(run(dir, 'new-post.mjs'), /give the title once/);
      refuses(run(dir, 'new-post.mjs', '   '), /title is empty/);
      refuses(run(dir, 'new-post.mjs', 'x'.repeat(71)), /71 characters; 70 at most/);
      refuses(run(dir, 'new-post.mjs', 'two\nlines'), /single line/);
      refuses(run(dir, 'new-post.mjs', '!!!'), /--slug/);
      refuses(run(dir, 'new-post.mjs', 'Dated', '--date', '2026-02-30'), /real date/);
      refuses(run(dir, 'new-post.mjs', 'Typo', '--descripton', 'x'), /Unknown option '--descripton'/);
      assert.deepEqual(readdirSync(join(dir, 'src/content/posts')), ['your-first-post.md']);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

describe('npm run new:page', () => {
  test('creates the page and puts it in the nav before the button', () => {
    const dir = siteCopy();
    try {
      const r = run(dir, 'new-page.mjs', 'About: "me"');
      assert.equal(r.code, 0, r.stderr);
      assert.equal(r.lines.length, 1);
      assert.match(r.lines[0], /^src\/pages\/about-me\.astro \(in the nav as "About: \\"me\\""\); replace its TODO description/);
      assert.match(read(dir, 'src/pages/about-me.astro'), /^const title = "About: \\"me\\"";$/m);
      const nav = JSON.parse(read(dir, 'src/site.json')).nav;
      assert.deepEqual(nav.at(-2), { label: 'About: "me"', href: '/about-me/' });
      assert.equal(nav.at(-1).button, true);
      refuses(run(dir, 'new-page.mjs', 'About me'), /already exists/);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('--no-nav leaves site.json byte-for-byte alone', () => {
    const dir = siteCopy();
    try {
      const before = read(dir, 'src/site.json');
      const r = run(dir, 'new-page.mjs', 'Hidden', '--no-nav', '--description', 'A page nobody links to from the header.');
      assert.equal(r.code, 0, r.stderr);
      assert.equal(r.lines[0], 'src/pages/hidden.astro (not in the nav)');
      assert.equal(read(dir, 'src/site.json'), before);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('refuses names the site or the server already answer', () => {
    const dir = siteCopy();
    try {
      for (const name of ['Healthz', 'Assets', 'Blog', '404', 'Sitemap index']) refuses(run(dir, 'new-page.mjs', name), /already used/);
      refuses(run(dir, 'new-page.mjs', 'Label', '--label', 'x'.repeat(31)), /nav label is 31 characters/);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

describe('npm run set:meta', () => {
  test('writes any characters safely and leaves the rest alone', () => {
    const dir = siteCopy();
    try {
      const before = JSON.parse(read(dir, 'src/site.json'));
      const title = 'Pete\'s "Shop": <b>& more';
      const r = run(dir, 'set-meta.mjs', '--title', title, '--description', 'Colons: fine; quotes "too"; {braces} and \\ too.');
      assert.equal(r.code, 0, r.stderr);
      assert.deepEqual(r.lines, ['src/site.json: set title, description']);
      const after = JSON.parse(read(dir, 'src/site.json'));
      assert.equal(after.title, title);
      assert.equal(after.description, 'Colons: fine; quotes "too"; {braces} and \\ too.');
      assert.deepEqual({ ...after, title: before.title, description: before.description }, before);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('rewriting the starter site.json changes no bytes (same layout as the writer)', () => {
    const dir = siteCopy();
    try {
      const before = read(dir, 'src/site.json');
      assert.equal(run(dir, 'set-meta.mjs', '--title', JSON.parse(before).title).code, 0);
      assert.equal(read(dir, 'src/site.json'), before);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('refuses the marker, the address, bad images and typos, changing nothing', () => {
    const dir = siteCopy();
    try {
      const before = read(dir, 'src/site.json');
      refuses(run(dir, 'set-meta.mjs', '--marker', 'New marker'), /SITE_MARKER in playbook\.env/);
      refuses(run(dir, 'set-meta.mjs', '--url', 'https://example.net'), /DOMAIN in playbook\.env/);
      refuses(run(dir, 'set-meta.mjs', '--image', 'javascript:alert(1)'), /https:\/\//);
      refuses(run(dir, 'set-meta.mjs', '--image', '/nope.png'), /public\/nope\.png does not exist/);
      refuses(run(dir, 'set-meta.mjs', '--titel', 'x'), /Unknown option '--titel'/);
      refuses(run(dir, 'set-meta.mjs', 'loose words'), /no --option in front/);
      refuses(run(dir, 'set-meta.mjs'), /nothing to change/);
      refuses(run(dir, 'set-meta.mjs', '--title', ''), /title is empty/);
      assert.equal(read(dir, 'src/site.json'), before);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

// ── Helpers shared with the site ──────────────────────────────────────────────
const { isSafeImage } = await import(join(starter, 'src/lib/safe-image.js'));
const { xmlText } = await import(join(starter, 'src/lib/xml.js'));
const { buildRss } = await import(join(starter, 'src/lib/rss.js'));
const { scriptJson } = await import(join(starter, 'src/lib/json-ld.js'));

describe('site helpers', () => {
  test('isSafeImage takes site paths and https only', () => {
    for (const ok of ['/og.png', '/images/card-1.jpg', 'https://cdn.example.com/a.png?w=1200']) assert.equal(isSafeImage(ok), true, ok);
    for (const bad of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'data:image/png;base64,AAAA', 'http://example.com/a.png', '//evil.example/a.png',
      'images/card.png', '/images/../secret.png', '/a b.png', 'https://example.com/"onerror=x', 'https://user:pw@example.com/a.png', '']) {
      assert.equal(isSafeImage(bad), false, bad);
    }
  });
  test('xmlText escapes all five characters and drops what XML forbids', () => {
    assert.equal(xmlText(`<b>&"'`), '&lt;b&gt;&amp;&quot;&apos;');
    assert.equal(xmlText(']]>'), ']]&gt;');
    assert.equal(xmlText(`a${String.fromCharCode(1)}b${String.fromCharCode(0xfffe)}c`), 'abc');
  });
  test('scriptJson cannot close its <script> and parses back to the same value', () => {
    const value = { name: '</script><script>alert(1)</script> & <!--', sep: String.fromCharCode(0x2028) };
    const out = scriptJson(value);
    assert.doesNotMatch(out, /[<>&]/);
    assert.deepEqual(JSON.parse(out), value);
  });

  const python = spawnSync('python3', ['--version']).status === 0;
  const parseXml = (xml) => spawnSync('python3', ['-c', 'import sys, xml.etree.ElementTree as E; r = E.fromstring(sys.stdin.buffer.read()); print("\\n".join(i.findtext("title") for i in r.iter("item")))'], { input: xml, encoding: 'utf8' });
  test('the RSS feed stays well-formed with a hostile title, and reads back exactly', { skip: !python && 'python3 not installed' }, () => {
    const title = `CDATA ]]> and <b>& "quoted" 'too'`;
    const feed = buildRss({ title: 'Site & <Co>', description: 'd', url: 'https://example.org' },
      [{ id: 'hostile', title, description: '<i>x</i> & y', date: new Date('2026-09-23T00:00:00Z') }]);
    assert.doesNotMatch(feed, /CDATA\[/);
    const r = parseXml(feed);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout.trim(), title);
    // Control: the same feed without escaping must NOT parse, or this test proves nothing.
    const naive = feed.replace(xmlText(title), title);
    assert.notEqual(naive, feed);
    assert.notEqual(parseXml(naive).status, 0);
  });
});

// ── Starter hygiene ───────────────────────────────────────────────────────────
describe('site-starter files', () => {
  test('.gitignore ignores the build folders at the top only', { skip: spawnSync('git', ['--version']).status !== 0 && 'git not installed' }, () => {
    const dir = temp();
    try {
      spawnSync('git', ['init', '-q', dir]);
      cpSync(join(starter, '.gitignore'), join(dir, '.gitignore'));
      const ignored = (path) => spawnSync('git', ['-C', dir, 'check-ignore', '-q', '--no-index', path]).status === 0;
      for (const path of ['dist/index.html', 'node_modules/astro/package.json', '.astro/types.d.ts', '.env', 'sub/.env']) assert.equal(ignored(path), true, `${path} should be ignored`);
      // An unanchored `dist/` also matches here, so a vendored library would
      // be missing from git while every local check (which builds the working
      // tree) passes and the server build (which builds from git) breaks.
      for (const path of ['public/vendor/lib/dist/lib.js', 'src/node_modules/x.js', 'src/.astro/x']) assert.equal(ignored(path), false, `${path} must be committed`);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  test('every template placeholder is one new-site.sh fills, in a file type it renders', () => {
    // new-site.sh renders these extensions and dies on an unknown placeholder.
    const known = new Set(['DOMAIN', 'SITE_NAME', 'SITE_PORT', 'SITE_MARKER', 'SITE_TITLE', 'SITE_DESCRIPTION']);
    const rendered = /\.(astro|mjs|json|yml|txt|css|md)$/;
    const walk = (d) => readdirSync(d).flatMap((n) => {
      const p = join(d, n);
      if (n === 'node_modules' || n === 'dist') return [];
      return statSync(p).isDirectory() ? walk(p) : [p];
    });
    const problems = [];
    for (const file of walk(starter)) {
      for (const m of readFileSync(file, 'utf8').matchAll(/\{\{([A-Z_]*)\}\}/g)) {
        if (!known.has(m[1])) problems.push(`${file}: {{${m[1]}}} is not a variable new-site.sh sets`);
        else if (!rendered.test(file)) problems.push(`${file}: new-site.sh does not render this file type`);
      }
    }
    assert.deepEqual(problems, []);
  });
});
