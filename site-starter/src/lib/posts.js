// The one place that decides which posts exist. Drafts show up in `npm run
// dev` so you can preview them, and never in a build, so an unfinished post
// can't ship by accident.
import { getCollection } from 'astro:content';

export async function publishedPosts() {
  const posts = await getCollection('posts', ({ data }) => import.meta.env.DEV || !data.draft);
  return posts.sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf() || a.id.localeCompare(b.id));
}

// Dates are written as YYYY-MM-DD and read as midnight UTC. Showing them in
// UTC keeps "September 23" from turning into "September 22" in a US browser.
export const isoDate = (date) => date.toISOString().slice(0, 10);
export const showDate = (date) =>
  date.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });
