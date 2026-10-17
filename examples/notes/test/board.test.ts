import assert from "node:assert/strict";
import { test } from "node:test";
import { moveCard, parseBoard, serializeBoard } from "../src/notes/board.ts";

const note = `---
board: true
---
# Lepton 0.1.5

Sürüm panosu.

## Yapılacak

- [ ] Not uygulaması
  CodeMirror + Milkdown
- [ ] Yayın

## Sürüyor

- [x] WPE işlevleri

## Bitti
`;

test("a board note reads as columns of cards, its head kept", () => {
  const board = parseBoard(note);
  assert.equal(board.head, "---\nboard: true\n---\n# Lepton 0.1.5\n\nSürüm panosu.\n");
  assert.deepEqual(
    board.columns.map((column) => [
      column.title,
      column.cards.map((card) => [card.text, card.done]),
    ]),
    [
      [
        "Yapılacak",
        [
          ["Not uygulaması", false],
          ["Yayın", false],
        ],
      ],
      ["Sürüyor", [["WPE işlevleri", true]]],
      ["Bitti", []],
    ],
  );
  assert.deepEqual(board.columns[0]?.cards[0]?.details, ["  CodeMirror + Milkdown"]);
});

test("moving a card writes back Markdown that reads as the moved board", () => {
  const moved = moveCard(parseBoard(note), { column: 0, card: 0 }, { column: 2, index: 0 });
  const text = serializeBoard(moved);
  assert.match(text, /## Bitti\n\n- \[ \] Not uygulaması\n {2}CodeMirror \+ Milkdown\n$/);
  assert.ok(
    text.startsWith(
      "---\nboard: true\n---\n# Lepton 0.1.5\n\nSürüm panosu.\n\n## Yapılacak\n\n- [ ] Yayın\n",
    ),
  );
  // Parse ∘ serialize is stable: a second round changes nothing.
  assert.equal(serializeBoard(parseBoard(text)), text);
});

test("a note without columns is all head, and out-of-range moves change nothing", () => {
  assert.deepEqual(parseBoard("# Just a note\n"), { head: "# Just a note\n", columns: [] });
  const board = parseBoard(note);
  assert.equal(moveCard(board, { column: 5, card: 0 }, { column: 0, index: 0 }), board);
});
