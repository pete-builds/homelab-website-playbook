// Change the site's name and summary:
//   npm run set:meta -- --title "..." --description "..." [--author "..."] [--image /images/card.png]
//
// Rewrites those fields in src/site.json, JSON-encoded, so any characters are
// safe. Pass "" to --author or --image to clear it. The marker and the address
// are deliberately NOT settable here: the live checks depend on both.
import { existsSync } from 'node:fs';
import { isSafeImage, IMAGE_HINT } from '../src/lib/safe-image.js';
import { at, die, oneLine, parse, readSite, writeSite } from './lib.mjs';

const USAGE = 'npm run set:meta -- [--title "..."] [--description "..."] [--author "..."] [--image /images/card.png]';
const { values, positionals } = parse(
  {
    title: { type: 'string' },
    description: { type: 'string' },
    author: { type: 'string' },
    image: { type: 'string' },
    marker: { type: 'string' },
    url: { type: 'string' },
  },
  USAGE,
);
if ('marker' in values) {
  die('the marker is not set here: the live checks look for it on the home page. Change SITE_MARKER in playbook.env, then "marker" in src/site.json to the same text.');
}
if ('url' in values) {
  die('the address is not set here: it has to match DOMAIN in playbook.env, the tunnel and DNS. Change DOMAIN first (see PLAYBOOK.md), then "url" in src/site.json.');
}
if (positionals.length) die(`"${positionals[0]}" has no --option in front of it. Usage: ${USAGE}`);
if (!Object.keys(values).length) die(`nothing to change. Usage: ${USAGE}`);

const site = readSite();
if ('title' in values) site.title = oneLine('title', values.title, 70);
if ('description' in values) site.description = oneLine('description', values.description, 160);
if ('author' in values) site.author = oneLine('author', values.author, 100, { allowEmpty: true });
if ('image' in values) {
  const image = oneLine('image', values.image, 500, { allowEmpty: true });
  if (image && !isSafeImage(image)) die(`image: ${IMAGE_HINT}`);
  if (image.startsWith('/') && !existsSync(at('public', image))) die(`image: public${image} does not exist; put the picture there first`);
  site.image = image;
}
writeSite(site);
console.log(`src/site.json: set ${Object.keys(values).join(', ')}`);
