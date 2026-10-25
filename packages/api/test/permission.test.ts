// A permission request written by the core's real log with its own payload
// (`lepton-invoke-check permission-events`), read by `src/permission.ts`.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { decodePermissionRequest } from "../src/payloads.ts";
import { decodeEvents, type WireLayout } from "../src/wire.ts";

const tool = fileURLToPath(
  new URL("../../../zig/zig-out/bin/lepton-invoke-check", import.meta.url),
);
const layout = new Function(
  `return (${execFileSync(tool, ["layout"], { encoding: "utf8" })});`,
)() as WireLayout;

test("a request decodes with its id and kinds", () => {
  const events = decodeEvents(layout, new Uint8Array(execFileSync(tool, ["permission-events"])));
  assert.deepEqual(events.map(decodePermissionRequest), [
    { id: 5, kinds: ["camera", "microphone"] },
  ]);
});

test("other events are not permission requests", () => {
  const events = decodeEvents(layout, new Uint8Array(execFileSync(tool, ["events"])));
  assert.equal(decodePermissionRequest(events[0] as (typeof events)[0]), undefined);
});
