// The RSS feed at /rss.xml: every published post, newest first. Written by
// hand (src/lib/rss.js) instead of pulling in a feed package.
import site from '../site.json';
import { publishedPosts } from '../lib/posts.js';
import { buildRss } from '../lib/rss.js';

export async function GET() {
  const posts = (await publishedPosts()).map((post) => ({
    id: post.id,
    title: post.data.title,
    description: post.data.description,
    date: post.data.date,
  }));
  return new Response(buildRss(site, posts), {
    headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' },
  });
}
