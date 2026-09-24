// Builds the RSS 2.0 feed as a string from plain data, so it can be tested
// without Astro (tests/test-check-dist.mjs in the playbook does exactly that).
// src/pages/rss.xml.js feeds it the published posts.
import { xmlText } from './xml.js';

/**
 * @param {{ title: string, description: string, url: string }} site
 * @param {{ id: string, title: string, description: string, date: Date }[]} posts
 */
export function buildRss(site, posts) {
  const home = new URL('/', site.url).href;
  const self = new URL('/rss.xml', site.url).href;
  const items = posts.map((post) => {
    const link = new URL(`/blog/${post.id}/`, site.url).href;
    return [
      '    <item>',
      `      <title>${xmlText(post.title)}</title>`,
      `      <link>${xmlText(link)}</link>`,
      `      <guid isPermaLink="true">${xmlText(link)}</guid>`,
      `      <pubDate>${post.date.toUTCString()}</pubDate>`,
      `      <description>${xmlText(post.description)}</description>`,
      '    </item>',
    ].join('\n');
  });
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
    '  <channel>',
    `    <title>${xmlText(site.title)}</title>`,
    `    <link>${xmlText(home)}</link>`,
    `    <description>${xmlText(site.description)}</description>`,
    '    <language>en</language>',
    `    <atom:link href="${xmlText(self)}" rel="self" type="application/rss+xml"/>`,
    ...items,
    '  </channel>',
    '</rss>',
    '',
  ].join('\n');
}
