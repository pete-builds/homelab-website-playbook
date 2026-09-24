import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://{{DOMAIN}}',
  output: 'static',
  integrations: [sitemap()],
  build: {
    // Every hashed file lands under /assets/, which nginx caches for a year.
    // Safe because the name changes whenever the content does.
    assets: 'assets',
    format: 'directory',
  },
});
