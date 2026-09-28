// Where a share picture may come from. Used by the blog schema
// (src/content.config.ts) and by `npm run set:meta`, so both refuse the same
// things. Plain JavaScript with no imports: Astro and bare Node both load it.
//
//   /images/card.png             a file in public/ on this site
//   https://example.com/a.jpg    a picture hosted somewhere else
//
// Anything else fails, including javascript: and data: (which would put code
// or a huge blob into every page's head) and //host (which hides a host).
export const IMAGE_HINT = 'use a path on this site like /images/card.png, or an https:// address';

export function isSafeImage(value) {
  if (typeof value !== 'string' || value.length > 500) return false;
  if (/^https:\/\//i.test(value)) {
    if (/[\s"'<>\\]/.test(value)) return false;
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && url.hostname.includes('.') && !url.username && !url.password;
    } catch {
      return false;
    }
  }
  return /^\/(?!\/)[A-Za-z0-9._~/-]+$/.test(value) && !value.split('/').some((part) => part === '..' || part === '.');
}
