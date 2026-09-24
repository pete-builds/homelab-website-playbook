// Shared by new-post.mjs, new-page.mjs and set-meta.mjs. Plain Node, no
// packages. Every problem ends the script with ONE line saying why.
import { readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

/** The site's folder, wherever the script is run from. */
export const root = fileURLToPath(new URL('..', import.meta.url));
export const at = (...parts) => join(root, ...parts);
export const rel = (path) => relative(root, path).split('\\').join('/');

export function die(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

/** Parse flags strictly: an unknown or misspelled option stops the script. */
export function parse(options, usage) {
  try {
    return parseArgs({ args: process.argv.slice(2), options, allowPositionals: true, strict: true });
  } catch (e) {
    die(`${e.message.split('. ')[0].replace(/\.$/, '')}. Usage: ${usage}`);
  }
}

/** One line of text between 1 and max characters, trimmed. */
export function oneLine(label, value, max, { allowEmpty = false } = {}) {
  const v = String(value ?? '').trim();
  const bad = [...v].some((c) => {
    const code = c.codePointAt(0);
    return code < 32 || code === 127 || code === 0x2028 || code === 0x2029;
  });
  if (bad) die(`${label} must be a single line of text`);
  if (!v && !allowEmpty) die(`${label} is empty`);
  if (v.length > max) die(`${label} is ${v.length} characters; ${max} at most`);
  return v;
}

/**
 * A file name from a title: "Crème Brûlée: A Love Story" -> "creme-brulee-a-love-story".
 * ASCII letters, digits and dashes only, so it is safe in a URL and on every OS.
 */
const LETTERS = { ß: 'ss', æ: 'ae', œ: 'oe', ø: 'o', đ: 'd', ð: 'd', ł: 'l', þ: 'th', ı: 'i' };
export function slugify(title) {
  return title
    .toLowerCase()
    .replace(/[ßæœøđðłþı]/g, (c) => LETTERS[c])
    .normalize('NFKD')
    .replace(/\p{M}/gu, '')
    .replace(/['’]/g, '')
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/, '');
}

/** A YAML value that is always read back as exactly this string. */
export const yamlString = (value) => JSON.stringify(value);

/** Today's date on this computer, YYYY-MM-DD. */
export function today() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export function readSite() {
  try {
    return JSON.parse(readFileSync(at('src/site.json'), 'utf8'));
  } catch (e) {
    die(`src/site.json can't be read: ${e.message}`);
  }
}

/** Same layout as JSON.stringify(x, null, 2) in Node and json.dump(indent=2) in Python. */
export function writeSite(site) {
  writeFileSync(at('src/site.json'), `${JSON.stringify(site, null, 2)}\n`);
}
