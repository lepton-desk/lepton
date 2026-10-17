/**
 * What the visual editor writes back: the user's edits, and nothing else.
 *
 * Milkdown prints the whole document in its own Markdown style (`-` for `*`, `**` for
 * `__`, its own escapes), so taking its output as the note reformatted every line the
 * user never touched. Instead the note is compared block by block (paragraph, heading,
 * list, code, table — markdown-it's top-level blocks): `before` is Milkdown's printing
 * of the note as it was opened, `after` its printing now. A block the user did not
 * change keeps the note's own text, byte for byte, with the blank lines around it;
 * only changed, added or removed blocks come from Milkdown.
 *
 * When the note and `before` do not split into the same number of blocks, the blocks
 * cannot be paired, and `after` is returned whole (the old behaviour) rather than guess.
 */

import MarkdownIt from "markdown-it";

const parser = new MarkdownIt({ html: true });

interface Split {
  /** Text before the first block, between blocks, and after the last: `blocks.length + 1`. */
  readonly gaps: readonly string[];
  readonly blocks: readonly string[];
}

/** Top-level blocks by markdown-it's line maps; the text between them kept as gaps. */
export function splitBlocks(text: string): Split {
  const lines = text.split("\n");
  const offsets: number[] = [0];
  for (const line of lines) offsets.push((offsets[offsets.length - 1] ?? 0) + line.length + 1);
  const at = (line: number) => Math.min(offsets[line] ?? text.length, text.length);
  const ranges: [number, number][] = [];
  for (const token of parser.parse(text, {})) {
    if (token.level !== 0 || token.map === null || token.nesting === -1) continue;
    const [start, end] = token.map;
    // A block's text ends before the newline after its last line; a list's map also
    // takes the blank line after it, which belongs to the gap.
    let to = Math.max(at(start), at(end) - 1);
    while (to > at(start) && text[to - 1] === "\n") to--;
    ranges.push([at(start), to]);
  }
  const gaps: string[] = [];
  const blocks: string[] = [];
  let last = 0;
  for (const [start, end] of ranges) {
    gaps.push(text.slice(last, start));
    blocks.push(text.slice(start, end));
    last = end;
  }
  gaps.push(text.slice(last));
  return { gaps, blocks };
}

type Step =
  | { readonly kind: "keep"; readonly before: number }
  | { readonly kind: "add"; readonly after: number };

/** The edit script from `a` to `b` by longest common subsequence of whole blocks. */
function diff(a: readonly string[], b: readonly string[]): Step[] {
  const table: number[][] = Array.from({ length: a.length + 1 }, () =>
    new Array<number>(b.length + 1).fill(0),
  );
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      const row = table[i] as number[];
      row[j] =
        a[i] === b[j]
          ? ((table[i + 1] as number[])[j + 1] as number) + 1
          : Math.max((table[i + 1] as number[])[j] as number, row[j + 1] as number);
    }
  }
  const steps: Step[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      steps.push({ kind: "keep", before: i });
      i++;
      j++;
    } else if (
      j < b.length &&
      (i >= a.length ||
        ((table[i] as number[])[j + 1] as number) >= ((table[i + 1] as number[])[j] as number))
    ) {
      steps.push({ kind: "add", after: j });
      j++;
    } else {
      // A block of `a` not in `b`: removed, so nothing is written for it.
      i++;
    }
  }
  return steps;
}

/**
 * A block as Milkdown printed it, with its escape of wiki links undone: it writes
 * `[[Note]]` as `\[\[Note]]` (measured with Milkdown 7.22 in Chrome), which no longer reads as a link.
 */
export function fromMilkdown(block: string): string {
  return block.replace(/\\\[\\\[/g, "[[");
}

/**
 * `original` with the blocks the user changed between `before` and `after` (Milkdown's
 * printings) replaced, every other block kept as `original` has it.
 */
export function mergeEdit(original: string, before: string, after: string): string {
  if (after === before) return original;
  const kept = splitBlocks(original);
  const was = splitBlocks(before);
  const now = splitBlocks(after);
  if (kept.blocks.length !== was.blocks.length) return fromMilkdown(after);

  let out = "";
  let previous: number | null = null; // the original block written last, if any
  const steps = diff(was.blocks, now.blocks);
  steps.forEach((step, index) => {
    const first = index === 0;
    if (step.kind === "keep") {
      const i = step.before;
      out += first ? (kept.gaps[0] ?? "") : previous === i - 1 ? (kept.gaps[i] ?? "\n\n") : "\n\n";
      out += kept.blocks[i] ?? "";
      previous = i;
    } else {
      out += first ? (kept.gaps[0] ?? "") : "\n\n";
      out += fromMilkdown(now.blocks[step.after] ?? "");
      previous = null;
    }
  });
  const lastKept = previous !== null && previous === kept.blocks.length - 1;
  out += lastKept ? (kept.gaps[kept.blocks.length] ?? "\n") : "\n";
  return out;
}
