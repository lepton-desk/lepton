/**
 * A note as a Trello-style board: a note whose front matter says `board: true` is shown
 * as columns of cards. A column is a `## heading`; a card is a list item under it
 * (`- [ ] text` or `- [x] text`), with any indented lines below it as the card's details.
 * Everything before the first column — front matter, an introduction — is kept as it was.
 *
 * The note stays plain Markdown: it opens in any editor, and the board writes back only
 * what the user changed by moving or ticking cards.
 */

export interface Card {
  readonly text: string;
  readonly done: boolean;
  /** Indented lines under the item, kept verbatim. */
  readonly details: readonly string[];
}

export interface Column {
  readonly title: string;
  readonly cards: readonly Card[];
}

export interface Board {
  /** The text before the first `## ` heading, unchanged. */
  readonly head: string;
  readonly columns: readonly Column[];
}

const itemPattern = /^[-*] (?:\[( |x|X)\] )?(.*)$/;

export function parseBoard(markdown: string): Board {
  const lines = markdown.split("\n");
  const first = lines.findIndex((line) => line.startsWith("## "));
  if (first === -1) return { head: markdown, columns: [] };
  const head = lines.slice(0, first).join("\n");
  const columns: { title: string; cards: Card[] }[] = [];
  let card: { text: string; done: boolean; details: string[] } | undefined;
  for (const line of lines.slice(first)) {
    if (line.startsWith("## ")) {
      columns.push({ title: line.slice(3).trim(), cards: [] });
      card = undefined;
      continue;
    }
    const column = columns[columns.length - 1];
    if (column === undefined) continue;
    const item = itemPattern.exec(line);
    if (item !== null) {
      card = { text: item[2] ?? "", done: item[1] === "x" || item[1] === "X", details: [] };
      column.cards.push(card);
    } else if (card !== undefined && /^\s+\S/.test(line)) {
      card.details.push(line);
    } else {
      card = undefined;
    }
  }
  return { head, columns };
}

export function serializeBoard(board: Board): string {
  const parts: string[] = [];
  const head = board.head.replace(/\n+$/, "");
  if (head !== "") parts.push(head, "");
  board.columns.forEach((column, index) => {
    if (index > 0) parts.push("");
    parts.push(`## ${column.title}`, "");
    for (const card of column.cards) {
      parts.push(`- [${card.done ? "x" : " "}] ${card.text}`, ...card.details);
    }
  });
  return `${parts.join("\n")}\n`;
}

/** The board with card `from.card` of column `from.column` moved to `to`. */
export function moveCard(
  board: Board,
  from: { readonly column: number; readonly card: number },
  to: { readonly column: number; readonly index: number },
): Board {
  const moving = board.columns[from.column]?.cards[from.card];
  if (moving === undefined || board.columns[to.column] === undefined) return board;
  const columns = board.columns.map((column) => [...column.cards]);
  columns[from.column]?.splice(from.card, 1);
  const target = columns[to.column] ?? [];
  target.splice(Math.min(to.index, target.length), 0, moving);
  return {
    head: board.head,
    columns: board.columns.map((column, i) => ({ title: column.title, cards: columns[i] ?? [] })),
  };
}

export function isBoard(data: Readonly<Record<string, unknown>>): boolean {
  return data.board === true;
}
