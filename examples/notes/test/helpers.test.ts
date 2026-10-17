import assert from "node:assert/strict";
import { test } from "node:test";
import { baseName, dailyNotePath, outline, rememberRecent } from "../src/notes/helpers.ts";

test("the outline is the headings, with their lines, never in code or front matter", () => {
  const note = [
    "---",
    "title: # not a heading",
    "---",
    "# Plans",
    "text",
    "```",
    "# a comment in code",
    "```",
    "## Next ##",
    "#tag is not a heading",
  ].join("\n");
  assert.deepEqual(outline(note), [
    { level: 1, text: "Plans", line: 4 },
    { level: 2, text: "Next", line: 9 },
  ]);
});

test("the daily note is named by the local date", () => {
  assert.equal(dailyNotePath(new Date(2026, 0, 5)), "2026-01-05.md");
  assert.equal(dailyNotePath(new Date(2026, 9, 18, 23, 59)), "2026-10-18.md");
});

test("recent vaults keep the newest first, once each, eight at most", () => {
  assert.deepEqual(rememberRecent(["/a", "/b"], "/b"), ["/b", "/a"]);
  const many = Array.from({ length: 10 }, (_, i) => `/v${i}`);
  assert.equal(rememberRecent(many, "/new").length, 8);
  assert.equal(baseName("/home/me/Notes/"), "Notes");
});
