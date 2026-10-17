/**
 * Markdown to HTML for the preview and for export: markdown-it, with `[[wiki links]]`
 * and `#tags` as clickable elements. Raw HTML in a note is not rendered (`html: false`):
 * a note is text, and a pasted `<script>` must stay text.
 */

import MarkdownIt from "markdown-it";
import { resolveLink, withoutCode } from "./links.ts";

const escapeHtml = (text: string): string =>
  text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

/** Turns `[[links]]` and `#tags` outside code into placeholders markdown-it keeps. */
function markLinks(text: string, paths: readonly string[]): string {
  const plain = withoutCode(text);
  let out = "";
  let last = 0;
  const pattern =
    /\[\[([^[\]|\n]+?)(?:\|([^[\]\n]+?))?\]\]|(^|[\s(])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)/gu;
  for (const match of plain.matchAll(pattern)) {
    const start = match.index;
    out += text.slice(last, start);
    if (match[1] !== undefined) {
      const target = match[1].trim();
      const label = (match[2] ?? match[1]).trim();
      const found = resolveLink(target, paths);
      out += `<a class="wikilink${found === undefined ? " wikilink--missing" : ""}" data-note="${escapeHtml(found ?? target)}">${escapeHtml(label)}</a>`;
    } else {
      const tag = match[4] ?? "";
      out += `${match[3] ?? ""}<a class="tag" data-tag="${escapeHtml(tag.toLowerCase())}">#${escapeHtml(tag)}</a>`;
    }
    last = start + match[0].length;
  }
  return out + text.slice(last);
}

export function renderNote(markdown: string, paths: readonly string[]): string {
  // HTML is off for the note's own text; the link placeholders are put in by token.
  const md = new MarkdownIt({ html: false, linkify: true, typographer: true });
  const placeholders: string[] = [];
  const marked = markLinks(markdown, paths).replace(
    /<a class="(?:wikilink|tag)[^>]*>.*?<\/a>/g,
    (anchor) => {
      placeholders.push(anchor);
      // Private-use characters: markdown-it replaces NUL, and a note will not contain these.
      return `\uE000${placeholders.length - 1}\uE001`;
    },
  );
  return md
    .render(marked)
    .replace(/\uE000(\d+)\uE001/g, (_, index: string) => placeholders[Number(index)] ?? "");
}

/** A standalone HTML document for export. */
export function exportDocument(title: string, body: string): string {
  return `<!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>body{max-width:46rem;margin:3rem auto;padding:0 1rem;font:16px/1.6 system-ui,sans-serif;color:#1d1d1f}pre,code{background:#f3f3f3;border-radius:4px}pre{padding:.8rem;overflow:auto}a.wikilink{color:#5b3cc4}a.tag{color:#0a7}</style>
</head>
<body>
${body}
</body>
</html>
`;
}
