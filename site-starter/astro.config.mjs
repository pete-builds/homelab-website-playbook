import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// src/site.json is the one place the site's address lives. Canonical links,
// the sitemap, robots.txt, the RSS feed and the share tags all read it.
const site = JSON.parse(readFileSync(new URL('./src/site.json', import.meta.url), 'utf8'));
let https = false;
try {
  https = new URL(site.url).protocol === 'https:';
} catch {}
if (!https) {
  // Without it every canonical link would be wrong; stop here and say why.
  throw new Error(`src/site.json: "url" must be the site's https:// address, like "https://example.com" (found ${JSON.stringify(site.url)})`);
}

export default defineConfig({
  site: site.url,
  output: 'static',
  integrations: [sitemap()],
  build: {
    // Every hashed file lands under /assets/, which nginx caches for a year.
    // Safe because the name changes whenever the content does.
    assets: 'assets',
    format: 'directory',
  },
  vite: {
    build: {
      // Never inline a small script or asset into the HTML. An inlined
      // <script> works in `astro dev` (no CSP there) and is silently blocked
      // in production, where the CSP allows scripts from this site's files only.
      assetsInlineLimit: 0,
    },
  },
});
