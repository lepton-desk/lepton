import assert from "node:assert/strict";
import { test } from "node:test";
import {
  extractLinks,
  extractTags,
  noteName,
  parseFrontmatter,
  resolveLink,
} from "../src/notes/links.ts";

test("wiki links with and without an alias, never inside code", () => {
  const text =
    "See [[Plans]] and [[Daily/2026-10-16|today]].\n`[[not a link]]`\n```\n[[nor this]]\n```\n[[ ]]";
  assert.deepEqual(
    extractLinks(text).map(({ target, alias }) => ({ target, alias })),
    [
      { target: "Plans", alias: undefined },
      { target: "Daily/2026-10-16", alias: "today" },
    ],
  );
  assert.equal(extractLinks("[[Plans]]")[0]?.at, 0);
});

test("tags are words after #, lowercased, without headings, numbers or code", () => {
  const text =
    "---\ntags: ignored\n---\n# Heading\nWork on #Lepton and #proje/notlar (#Türkçe).\nIssue #42, a#b, `#code`";
  assert.deepEqual(extractTags(text), ["lepton", "proje/notlar", "türkçe"]);
});

test("front matter is flat key: value pairs, typed", () => {
  const parsed = parseFrontmatter("---\nboard: true\ncount: 3\ntitle: Plan: A\n---\n# Body\n");
  assert.deepEqual(parsed.data, { board: true, count: 3, title: "Plan: A" });
  assert.equal(parsed.body, "# Body\n");
  assert.deepEqual(parseFrontmatter("no front matter").data, {});
  assert.equal(parseFrontmatter("---\nunclosed").body, "---\nunclosed");
});

test("a link resolves by exact path first, then by name with the shortest path", () => {
  const paths = [
    "Plans.md",
    "Archive/Plans.md",
    "Daily/2026-10-16.md",
    "a/b/Ideas.md",
    "c/Ideas.md",
  ];
  assert.equal(resolveLink("plans", paths), "Plans.md");
  assert.equal(resolveLink("Archive/Plans", paths), "Archive/Plans.md");
  assert.equal(resolveLink("Ideas", paths), "c/Ideas.md");
  assert.equal(resolveLink("2026-10-16", paths), "Daily/2026-10-16.md");
  assert.equal(resolveLink("Missing", paths), undefined);
  assert.equal(resolveLink("Nope/Plans", paths), undefined);
  assert.equal(noteName("Daily/2026-10-16.md"), "2026-10-16");
});
