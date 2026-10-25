// Download events written by the core's real log with its own payloads
// (`lepton-invoke-check download-events`), read by `src/download.ts`.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { decodeDownload } from "../src/payloads.ts";
import { decodeEvents, type WireLayout } from "../src/wire.ts";

const tool = fileURLToPath(
  new URL("../../../zig/zig-out/bin/lepton-invoke-check", import.meta.url),
);
const layout = new Function(
  `return (${execFileSync(tool, ["layout"], { encoding: "utf8" })});`,
)() as WireLayout;

test("a download's events decode with the core's payloads", () => {
  const events = decodeEvents(layout, new Uint8Array(execFileSync(tool, ["download-events"])));
  const decoded = events.map(decodeDownload);
  assert.deepEqual(decoded, [
    { kind: "started", id: 7, name: "rapor şubat.pdf" },
    { kind: "progress", id: 7, received: 1024, expected: 4096 },
    { kind: "finished", id: 7, path: "/home/u/İndirilenler/rapor şubat.pdf" },
    { kind: "failed", id: 8, message: "Connection refused" },
  ]);
});

test("other events are not downloads", () => {
  const events = decodeEvents(layout, new Uint8Array(execFileSync(tool, ["events"])));
  assert.equal(decodeDownload(events[0] as (typeof events)[0]), undefined);
});
