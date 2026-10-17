/**
 * What a note says about other notes: `[[wiki links]]`, `#tags` and front matter — the
 * pieces Obsidian builds its links, backlinks and tag pane from. Pure functions over the
 * note's text, so every rule here is tested without a window.
 */

export interface WikiLink {
  /** The note named, as written: `[[Daily/2026-10-16]]` → `Daily/2026-10-16`. */
  readonly target: string;
  /** The text shown instead: `[[Plans|our plans]]` → `our plans`. */
  readonly alias?: string;
  /** Where `[[` starts in the text. */
  readonly at: number;
}

const linkPattern = /\[\[([^[\]|\n]+?)(?:\|([^[\]\n]+?))?\]\]/g;
/** `#tag` or `#nested/tag` after a space or at a line start; not `#` headings or `a#b`. */
const tagPattern = /(?:^|[\s(])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)/gu;
const fencePattern = /^(```|~~~)/;

/** The text with fenced code blocks and inline code blanked out, keeping every offset. */
export function withoutCode(text: string): string {
  const lines = text.split("\n");
  let inFence = false;
  const kept = lines.map((line) => {
    if (fencePattern.test(line.trimStart())) {
      inFence = !inFence;
      return " ".repeat(line.length);
    }
    if (inFence) return " ".repeat(line.length);
    return line.replace(/`[^`\n]*`/g, (code) => " ".repeat(code.length));
  });
  return kept.join("\n");
}

export function extractLinks(text: string): WikiLink[] {
  const links: WikiLink[] = [];
  for (const match of withoutCode(text).matchAll(linkPattern)) {
    const target = (match[1] ?? "").trim();
    if (target === "") continue;
    const alias = match[2]?.trim();
    links.push(
      alias === undefined ? { target, at: match.index } : { target, alias, at: match.index },
    );
  }
  return links;
}

export function extractTags(text: string): string[] {
  const found = new Set<string>();
  const body = parseFrontmatter(text).body;
  for (const match of withoutCode(body).matchAll(tagPattern)) {
    const tag = match[1];
    // A tag that is only digits is an issue number (#42), not a tag — as in Obsidian.
    if (tag !== undefined && !/^\d+$/.test(tag)) found.add(tag.toLowerCase());
  }
  return [...found].sort();
}

export type FrontValue = string | boolean | number;

export interface Frontmatter {
  readonly data: Readonly<Record<string, FrontValue>>;
  /** The text after the closing `---`. */
  readonly body: string;
  /** Where the body starts in the text. */
  readonly bodyAt: number;
}

/**
 * `---` front matter as flat `key: value` pairs. Not a YAML parser: the keys this
 * application reads (`board`, `tags`, `title`) are flat, and an unexpected shape is
 * kept as text rather than guessed at.
 */
export function parseFrontmatter(text: string): Frontmatter {
  if (!text.startsWith("---\n")) return { data: {}, body: text, bodyAt: 0 };
  const end = text.indexOf("\n---", 4);
  if (end === -1) return { data: {}, body: text, bodyAt: 0 };
  const data: Record<string, FrontValue> = {};
  for (const line of text.slice(4, end).split("\n")) {
    const colon = line.indexOf(":");
    if (colon <= 0) continue;
    const key = line.slice(0, colon).trim();
    const raw = line.slice(colon + 1).trim();
    data[key] =
      raw === "true"
        ? true
        : raw === "false"
          ? false
          : /^-?\d+(\.\d+)?$/.test(raw)
            ? Number(raw)
            : raw;
  }
  const after = text.indexOf("\n", end + 4);
  const bodyAt = after === -1 ? text.length : after + 1;
  return { data, body: text.slice(bodyAt), bodyAt };
}

/** A note's name: its file name without `.md`. */
export function noteName(path: string): string {
  const base = path.slice(path.lastIndexOf("/") + 1);
  return base.toLowerCase().endsWith(".md") ? base.slice(0, -3) : base;
}

/**
 * The note `[[target]]` means, among `paths` (relative to the vault): an exact path
 * first (`Daily/2026-10-16`), else the note with that name anywhere, the shortest path
 * winning — Obsidian's rule. Case does not matter. `undefined` when none exists.
 */
export function resolveLink(target: string, paths: readonly string[]): string | undefined {
  const wanted = target.toLowerCase().replace(/\.md$/, "");
  const exact = paths.find((path) => path.toLowerCase().replace(/\.md$/, "") === wanted);
  if (exact !== undefined) return exact;
  if (wanted.includes("/")) return undefined;
  const named = paths.filter((path) => noteName(path).toLowerCase() === wanted);
  return named.sort((a, b) => a.length - b.length || (a < b ? -1 : 1))[0];
}
