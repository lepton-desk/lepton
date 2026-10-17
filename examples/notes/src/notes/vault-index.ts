/**
 * What the whole vault knows: which note links to which (backlinks), which tags exist
 * and where, and text search — rebuilt from the notes' text, no database.
 */

import { extractLinks, extractTags, noteName, resolveLink } from "./links.ts";

export interface IndexedNote {
  readonly path: string;
  readonly text: string;
}

export interface SearchHit {
  readonly path: string;
  /** The line the match is on, trimmed. */
  readonly line: string;
  readonly lineNumber: number;
}

export class VaultIndex {
  readonly paths: readonly string[];
  private readonly texts: ReadonlyMap<string, string>;
  private readonly incoming = new Map<string, Set<string>>();
  private readonly tagged = new Map<string, Set<string>>();

  constructor(notes: readonly IndexedNote[]) {
    this.paths = notes.map((note) => note.path).sort();
    this.texts = new Map(notes.map((note) => [note.path, note.text]));
    for (const note of notes) {
      for (const link of extractLinks(note.text)) {
        const target = resolveLink(link.target, this.paths);
        if (target === undefined || target === note.path) continue;
        let from = this.incoming.get(target);
        if (from === undefined) {
          from = new Set();
          this.incoming.set(target, from);
        }
        from.add(note.path);
      }
      for (const tag of extractTags(note.text)) {
        let notesWithTag = this.tagged.get(tag);
        if (notesWithTag === undefined) {
          notesWithTag = new Set();
          this.tagged.set(tag, notesWithTag);
        }
        notesWithTag.add(note.path);
      }
    }
  }

  /** Notes linking to `path`, sorted. */
  backlinks(path: string): string[] {
    return [...(this.incoming.get(path) ?? [])].sort();
  }

  /** Every tag with how many notes carry it, most used first. */
  tags(): { readonly tag: string; readonly count: number }[] {
    return [...this.tagged]
      .map(([tag, notes]) => ({ tag, count: notes.size }))
      .sort((a, b) => b.count - a.count || (a.tag < b.tag ? -1 : 1));
  }

  notesTagged(tag: string): string[] {
    return [...(this.tagged.get(tag.toLowerCase()) ?? [])].sort();
  }

  /** Lines containing every word of `query`, case-insensitive; at most `limit`. */
  search(query: string, limit = 200): SearchHit[] {
    const words = query
      .toLocaleLowerCase("tr")
      .split(/\s+/)
      .filter((word) => word !== "");
    if (words.length === 0) return [];
    const hits: SearchHit[] = [];
    for (const path of this.paths) {
      const lines = (this.texts.get(path) ?? "").split("\n");
      for (const [index, line] of lines.entries()) {
        const lower = line.toLocaleLowerCase("tr");
        if (words.every((word) => lower.includes(word))) {
          hits.push({ path, line: line.trim(), lineNumber: index + 1 });
          if (hits.length === limit) return hits;
        }
      }
    }
    return hits;
  }

  /**
   * Notes whose name contains the letters of `query` in order (fuzzy, as a quick
   * switcher matches), best first: an exact name, then a prefix, then the shortest.
   */
  findNotes(query: string, limit = 50): string[] {
    const wanted = query.toLocaleLowerCase("tr");
    const score = (path: string): number | undefined => {
      const name = noteName(path).toLocaleLowerCase("tr");
      if (wanted === "") return 0;
      if (name === wanted) return 0;
      if (name.startsWith(wanted)) return 1;
      let at = 0;
      for (const char of path.toLocaleLowerCase("tr")) if (char === wanted[at]) at += 1;
      return at === wanted.length ? 2 : undefined;
    };
    return this.paths
      .map((path) => ({ path, rank: score(path) }))
      .filter((entry): entry is { path: string; rank: number } => entry.rank !== undefined)
      .sort((a, b) => a.rank - b.rank || a.path.length - b.path.length)
      .slice(0, limit)
      .map((entry) => entry.path);
  }
}
