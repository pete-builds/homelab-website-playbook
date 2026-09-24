// Post-build gate. Runs locally in deploy.sh AND inside the Docker build, so a
// broken site can never become the running image. Exits non-zero on any failure.
//
//   1. the pages that must exist do (index, 404, sitemap)
//   2. every local link and asset referenced in the HTML exists in dist/
//   3. no template placeholder like {{DOMAIN}} survived into the output
//   4. no inline <script>: the CSP (script-src 'self') would block it in
//      production while it works in `astro dev`, which has no CSP
//   5. the build id is baked in, and matches PUBLIC_BUILD_ID when one is set
//   6. the whole site stays under a size budget
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';

const dist = resolve('dist');
const BUDGET_BYTES = 5 * 1024 * 1024;
const errors = [];
const fail = (msg) => errors.push(msg);

if (!existsSync(dist)) {
  console.error('FAIL dist/ does not exist. Run the build first.');
  process.exit(1);
}

const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
const files = walk(dist);
const html = files.filter((f) => f.endsWith('.html'));

for (const must of ['index.html', '404.html', 'sitemap-index.xml']) {
  if (!existsSync(join(dist, must))) fail(`missing ${must}`);
}

const want = process.env.PUBLIC_BUILD_ID;
for (const file of html) {
  const rel = file.slice(dist.length);
  const text = readFileSync(file, 'utf8');

  const leftover = text.match(/\{\{[A-Z_]+\}\}/);
  if (leftover) fail(`${rel}: unrendered placeholder ${leftover[0]}`);

  for (const m of text.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (!/\bsrc=/.test(m[1]) && m[2].trim() && !/type=["']application\/(ld\+)?json["']/.test(m[1])) {
      fail(`${rel}: inline <script> would be blocked by the CSP in production`);
    }
  }

  const build = text.match(/<meta name="build" content="build:([^"]+)"/);
  if (!build) fail(`${rel}: no build id meta tag`);
  else if (want && build[1] !== want) fail(`${rel}: build id ${build[1]}, expected ${want} (stale dist/?)`);

  for (const m of text.matchAll(/\b(?:href|src)="([^"#?]+)[^"]*"/g)) {
    const url = m[1];
    if (/^(https?:|mailto:|tel:|data:|\/\/)/.test(url)) continue;
    const base = url.startsWith('/') ? dist : dirname(file);
    const target = join(base, url);
    const ok = existsSync(target) && (statSync(target).isFile() || existsSync(join(target, 'index.html')));
    if (!ok) fail(`${rel}: broken link ${url}`);
  }
}

const total = files.reduce((n, f) => n + statSync(f).size, 0);
if (total > BUDGET_BYTES) fail(`dist/ is ${(total / 1048576).toFixed(1)} MB, budget ${BUDGET_BYTES / 1048576} MB`);

if (errors.length) {
  for (const e of errors) console.error(`FAIL ${e}`);
  process.exit(1);
}
console.log(`check-dist OK: ${html.length} pages, ${files.length} files, ${(total / 1024).toFixed(0)} KB`);
