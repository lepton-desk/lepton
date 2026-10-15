// Event frames written by the core's real log (`lepton-invoke-check events`), read by
// `src/event.ts`; state bits taken from the same layout the page gets.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { WireLayout } from "../src/core.ts";
import { decodeEvents } from "../src/event.ts";
import { decodeState } from "../src/window.ts";

const tool = fileURLToPath(
  new URL("../../../zig/zig-out/bin/lepton-invoke-check", import.meta.url),
);
const layout = new Function(
  `return (${execFileSync(tool, ["layout"], { encoding: "utf8" })});`,
)() as WireLayout;

test("events from the core's log decode with their names, data and numbers", () => {
  const bytes = new Uint8Array(execFileSync(tool, ["events"]));
  const events = decodeEvents(layout, bytes);
  assert.equal(events.length, 2);
  assert.equal(events[0]?.name, "window.state");
  assert.equal(events[0]?.sequence, 1n);
  assert.equal(events[1]?.name, "notes.saved");
  assert.equal(events[1]?.sequence, 2n);
  assert.equal(new TextDecoder().decode(events[1]?.payload), "draft.md");
});

test("a truncated or foreign frame is refused", () => {
  const bytes = new Uint8Array(execFileSync(tool, ["events"]));
  assert.throws(() => decodeEvents(layout, bytes.subarray(0, bytes.byteLength - 1)), RangeError);
  const foreign = bytes.slice();
  foreign[layout.wireKindOffset] = 99;
  assert.throws(() => decodeEvents(layout, foreign), /not an event/);
  assert.deepEqual(decodeEvents(layout, new Uint8Array(0)), []);
});

test("window state bits decode with the core's bit values", () => {
  Reflect.set(globalThis, "__lepton", { layout });
  try {
    const bits = layout.events.windowState;
    assert.deepEqual(decodeState(bits.maximized | bits.active), {
      maximized: true,
      fullscreen: false,
      active: true,
    });
    assert.deepEqual(decodeState(0), { maximized: false, fullscreen: false, active: false });
  } finally {
    Reflect.deleteProperty(globalThis, "__lepton");
  }
});
