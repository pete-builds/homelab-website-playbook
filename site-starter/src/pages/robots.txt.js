// robots.txt, built from src/site.json so the sitemap address can never
// point at a domain the site no longer uses.
import site from '../site.json';

export function GET() {
  const sitemap = new URL('/sitemap-index.xml', site.url).href;
  return new Response(`User-agent: *\nAllow: /\n\nSitemap: ${sitemap}\n`, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
