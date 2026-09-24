import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// src/site.json is the one place the site's address lives. Canonical links,
// the sitemap, robots.txt, the RSS feed and the share tags all read it.
const site = JSON.parse(readFileSync(new URL('./src/site.json', import.meta.url), 'utf8'));

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
});
