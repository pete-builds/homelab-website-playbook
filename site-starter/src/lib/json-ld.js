// JSON for a <script type="application/ld+json"> block. JSON.stringify alone
// is not safe there: a title containing "</script>" would end the tag early
// and the rest would render as page text. Writing < > & as \u escapes keeps
// the JSON identical once parsed, and leaves nothing an HTML parser reacts to.
export function scriptJson(value) {
  return JSON.stringify(value).replace(/[<>&\u2028\u2029]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
}
