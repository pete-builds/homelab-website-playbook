// Text for XML (the RSS feed). Every text field goes through xmlText, so a
// title like `<b>&` or `]]>` stays text and the feed stays well-formed. No
// CDATA: escaping all five characters is simpler and has no edge cases.
//
// XML 1.0 also forbids most control characters even when escaped, so they
// are dropped rather than breaking every feed reader.
const ENTITIES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' };

export function xmlText(value) {
  return String(value)
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, '')
    .replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '')
    .replace(/[&<>"']/g, (c) => ENTITIES[c]);
}
