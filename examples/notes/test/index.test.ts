import assert from "node:assert/strict";
import { test } from "node:test";
import { renderNote } from "../src/notes/render.ts";
import { VaultIndex } from "../src/notes/vault-index.ts";

const notes = [
  { path: "Plans.md", text: "# Plans\nShip [[Lepton]] 0.1.5. #release #lepton" },
  { path: "Lepton.md", text: "Framework notes. See [[Plans|the plan]]. #lepton" },
  { path: "Daily/2026-10-16.md", text: "Worked on [[Lepton]] and [[Missing]].\nŞubat raporu" },
];

test("backlinks, tags and search across the vault", () => {
  const index = new VaultIndex(notes);
  assert.deepEqual(index.backlinks("Lepton.md"), ["Daily/2026-10-16.md", "Plans.md"]);
  assert.deepEqual(index.backlinks("Plans.md"), ["Lepton.md"]);
  assert.deepEqual(index.tags(), [
    { tag: "lepton", count: 2 },
    { tag: "release", count: 1 },
  ]);
  assert.deepEqual(index.notesTagged("LEPTON"), ["Lepton.md", "Plans.md"]);
  assert.deepEqual(
    index.search("şubat RAPOR").map((hit) => [hit.path, hit.lineNumber]),
    [["Daily/2026-10-16.md", 2]],
  );
  assert.deepEqual(index.findNotes("lep"), ["Lepton.md"]);
  assert.deepEqual(index.findNotes("d26"), ["Daily/2026-10-16.md"]);
});

test("the preview links notes and tags and never renders a note's raw HTML", () => {
  const html = renderNote(
    "Go to [[Lepton]] or [[Nowhere|away]] #lepton\n\n<script>alert(1)</script>\n\n`[[code]]`",
    ["Lepton.md"],
  );
  assert.match(html, /<a class="wikilink" data-note="Lepton.md">Lepton<\/a>/);
  assert.match(html, /<a class="wikilink wikilink--missing" data-note="Nowhere">away<\/a>/);
  assert.match(html, /<a class="tag" data-tag="lepton">#lepton<\/a>/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /<code>\[\[code\]\]<\/code>/);
});
