/**
 * A `board: true` note as columns of cards. Dragging a card moves it (within a column or
 * across), the box ticks it, and cards and columns can be added; every change is written
 * back as the note's Markdown through `onChange`, so the board and the text never differ.
 */

import { type JSX, useMemo, useState } from "react";
import { type Board, moveCard, parseBoard, serializeBoard } from "../notes/board.ts";

interface Props {
  readonly text: string;
  readonly onChange: (text: string) => void;
}

interface Dragged {
  readonly column: number;
  readonly card: number;
}

export function BoardView({ text, onChange }: Props): JSX.Element {
  const board = useMemo(() => parseBoard(text), [text]);
  const [dragged, setDragged] = useState<Dragged | null>(null);
  const [adding, setAdding] = useState<number | null>(null);
  const write = (next: Board) => onChange(serializeBoard(next));

  const toggle = (column: number, card: number) =>
    write({
      head: board.head,
      columns: board.columns.map((c, i) =>
        i !== column
          ? c
          : {
              title: c.title,
              cards: c.cards.map((k, j) => (j === card ? { ...k, done: !k.done } : k)),
            },
      ),
    });

  const addCard = (column: number, cardText: string) =>
    write({
      head: board.head,
      columns: board.columns.map((c, i) =>
        i === column
          ? { title: c.title, cards: [...c.cards, { text: cardText, done: false, details: [] }] }
          : c,
      ),
    });

  const drop = (column: number, index: number) => {
    if (dragged === null) return;
    setDragged(null);
    // Dropping lower in the same column: the card leaves its old place first.
    const at = dragged.column === column && dragged.card < index ? index - 1 : index;
    write(moveCard(board, dragged, { column, index: at }));
  };

  if (board.columns.length === 0) {
    return (
      <div className="board board--empty">
        <p className="muted">This board has no columns yet: a column is a “## heading”.</p>
        <button
          type="button"
          className="button"
          onClick={() => write({ head: board.head, columns: [{ title: "To do", cards: [] }] })}
        >
          Add a column
        </button>
      </div>
    );
  }

  return (
    <div className="board">
      {board.columns.map((column, c) => (
        <section
          // A column has no identity in the Markdown but its place and title.
          // biome-ignore lint/suspicious/noArrayIndexKey: two columns may share a title
          key={`${c}-${column.title}`}
          className="board__column"
          aria-label={column.title}
          onDragOver={(event) => event.preventDefault()}
          onDrop={() => drop(c, column.cards.length)}
        >
          <h2>
            {column.title} <span className="muted">{column.cards.length}</span>
          </h2>
          <ul>
            {column.cards.map((card, k) => (
              <li
                // A card is a list item: its place is its identity.
                // biome-ignore lint/suspicious/noArrayIndexKey: two cards may share a text
                key={`${k}-${card.text}`}
                className={`card${card.done ? " card--done" : ""}`}
                draggable
                onDragStart={(event) => {
                  event.dataTransfer.effectAllowed = "move";
                  event.dataTransfer.setData("text/plain", card.text);
                  setDragged({ column: c, card: k });
                }}
                onDragEnd={() => setDragged(null)}
                onDragOver={(event) => event.preventDefault()}
                onDrop={(event) => {
                  event.stopPropagation();
                  drop(c, k);
                }}
              >
                <label>
                  <input type="checkbox" checked={card.done} onChange={() => toggle(c, k)} />
                  <span>{card.text}</span>
                </label>
                {card.details.length > 0 && (
                  <p className="card__details">{card.details.map((d) => d.trim()).join(" ")}</p>
                )}
              </li>
            ))}
          </ul>
          {adding === c ? (
            <form
              onSubmit={(event) => {
                event.preventDefault();
                const value = new FormData(event.currentTarget).get("card");
                if (typeof value === "string" && value.trim() !== "") addCard(c, value.trim());
                setAdding(null);
              }}
            >
              <input
                name="card"
                aria-label={`New card in ${column.title}`}
                // biome-ignore lint/a11y/noAutofocus: the field exists only because the user asked for it
                autoFocus
                onBlur={() => setAdding(null)}
                onKeyDown={(event) => event.key === "Escape" && setAdding(null)}
              />
            </form>
          ) : (
            <button type="button" className="board__add" onClick={() => setAdding(c)}>
              + Add a card
            </button>
          )}
        </section>
      ))}
      <button
        type="button"
        className="board__add board__add--column"
        onClick={() =>
          write({
            head: board.head,
            columns: [...board.columns, { title: `Column ${board.columns.length + 1}`, cards: [] }],
          })
        }
      >
        + Add a column
      </button>
    </div>
  );
}
