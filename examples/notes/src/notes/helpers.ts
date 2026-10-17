/**
 * Small pure pieces the screens use: the outline of a note, the daily note's name, the
 * list of recently opened vaults.
 */

import { parseFrontmatter, withoutCode } from "./links.ts";

export interface Heading {
  readonly level: number;
  readonly text: string;
  /** 1-based, in the whole note (front matter included). */
  readonly line: number;
}

/** The note's ATX headings (`#` to `######`), never inside code or front matter. */
export function outline(markdown: string): Heading[] {
  const front = parseFrontmatter(markdown).bodyAt;
  const skipped = markdown.slice(0, front).split("\n").length - 1;
  const lines = withoutCode(markdown.slice(front)).split("\n");
  const out: Heading[] = [];
  lines.forEach((line, index) => {
    const match = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (match?.[1] !== undefined && match[2] !== undefined) {
      out.push({ level: match[1].length, text: match[2], line: skipped + index + 1 });
    }
  });
  return out;
}

/** `YYYY-MM-DD.md` for `date` in local time, as Obsidian names daily notes. */
export function dailyNotePath(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}.md`;
}

/** `root` first, then the earlier ones without it, at most `max`. */
export function rememberRecent(recent: readonly string[], root: string, max = 8): string[] {
  return [root, ...recent.filter((other) => other !== root)].slice(0, max);
}

/** The last path segment: a vault's or folder's display name. */
export function baseName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}
