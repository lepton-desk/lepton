import assert from "node:assert/strict";
import { test } from "node:test";
import { mergeEdit, splitBlocks } from "../src/notes/merge.ts";

// The note as the user wrote it, and the same note in the style Milkdown prints:
// `-` list markers, `**` for `__`, one blank line between blocks.
const original = [
  "# Plans",
  "",
  "",
  "* first",
  "* second",
  "",
  "Some __bold__ text.",
  "",
  "Last line.",
  "",
].join("\n");
const printed = [
  "# Plans",
  "",
  "- first",
  "- second",
  "",
  "Some **bold** text.",
  "",
  "Last line.",
  "",
].join("\n");

test("blocks are markdown-it's top-level ones, the gaps kept", () => {
  const split = splitBlocks(original);
  assert.deepEqual(split.blocks, [
    "# Plans",
    "* first\n* second",
    "Some __bold__ text.",
    "Last line.",
  ]);
  assert.equal(split.blocks.length + 1, split.gaps.length);
  // Gaps and blocks interleaved are the note again, nothing lost.
  const rebuilt = split.blocks.reduce(
    (text, block, i) => text + block + (split.gaps[i + 1] ?? ""),
    split.gaps[0] ?? "",
  );
  assert.equal(rebuilt, original);
});

test("an untouched note comes back byte for byte", () => {
  assert.equal(mergeEdit(original, printed, printed), original);
});

test("editing one paragraph rewrites that paragraph only", () => {
  const after = printed.replace("Last line.", "Last line, edited.");
  assert.equal(
    mergeEdit(original, printed, after),
    original.replace("Last line.", "Last line, edited."),
  );
});

test("a block added or removed leaves the others as they were", () => {
  const added = printed.replace("Last line.", "A new paragraph.\n\nLast line.");
  const merged = mergeEdit(original, printed, added);
  assert.ok(merged.includes("* first\n* second"), merged);
  assert.ok(merged.includes("Some __bold__ text."), merged);
  assert.ok(merged.includes("A new paragraph.\n\nLast line."), merged);

  const removed = printed.replace("Some **bold** text.\n\n", "");
  assert.equal(
    mergeEdit(original, printed, removed),
    "# Plans\n\n\n* first\n* second\n\nLast line.\n",
  );
});

test("when the blocks cannot be paired, Milkdown's text is taken whole", () => {
  const after = printed.replace("Last line.", "Last.");
  assert.equal(mergeEdit("one block only\n", printed, after), after);
});

test("a wiki link in a block Milkdown printed reads as a link again", () => {
  const before = "Some text.\n";
  const after = "Some text and \\[\\[Plans]] now.\n";
  assert.equal(mergeEdit("Some text.\n", before, after), "Some text and [[Plans]] now.\n");
});
