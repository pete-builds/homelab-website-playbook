// Start a blog post:  npm run new:post -- "Title" [--description "One sentence."]
//
// Writes src/content/posts/<title-as-a-file-name>.md with today's date and
// draft: true, so an unfinished post can't ship. Refuses to overwrite a post.
// Values are written JSON-quoted, so a colon or quote in the title can't
// break the settings block.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { at, die, oneLine, parse, rel, slugify, today, yamlString } from './lib.mjs';

const USAGE = 'npm run new:post -- "Title" [--description "One sentence."] [--date YYYY-MM-DD] [--slug file-name]';
const DESCRIPTION_TODO = 'TODO: one sentence for search results and link previews.';

const { values, positionals } = parse(
  { description: { type: 'string' }, date: { type: 'string' }, slug: { type: 'string' } },
  USAGE,
);
if (positionals.length !== 1) die(`give the title once, in quotes. Usage: ${USAGE}`);
const title = oneLine('title', positionals[0], 70);
const description = values.description === undefined ? DESCRIPTION_TODO : oneLine('description', values.description, 160);

const date = values.date ?? today();
const valid = /^\d{4}-\d{2}-\d{2}$/.test(date) && new Date(`${date}T00:00:00Z`).toISOString().startsWith(date);
if (!valid) die(`--date must be a real date written YYYY-MM-DD, like ${today()}`);

const slug = values.slug ?? slugify(title);
if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) {
  die(values.slug !== undefined ? '--slug: lowercase letters, digits and single dashes only' : 'the title has no letters or digits to make a file name from; add --slug my-post');
}

const file = at('src/content/posts', `${slug}.md`);
const text = [
  '---',
  `title: ${yamlString(title)}`,
  `description: ${yamlString(description)}`,
  `date: ${date}`,
  'draft: true',
  '---',
  '',
  'Write here. Start each section with "## A heading": the title is already the page\'s main heading.',
  '',
].join('\n');
mkdirSync(dirname(file), { recursive: true });
try {
  writeFileSync(file, text, { flag: 'wx' });
} catch (e) {
  if (e.code === 'EEXIST') die(`${rel(file)} already exists; choose another title or pass --slug`);
  throw e;
}
console.log(rel(file));
console.log(description === DESCRIPTION_TODO
  ? 'To publish: write the description, then set draft: false in that file.'
  : 'To publish: set draft: false in that file.');
