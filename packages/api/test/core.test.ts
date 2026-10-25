// Both ends are shipped code: frames built by `src/core.ts` are answered by the core's
// own `invoke.handle`, behind `zig build invoke-check` — the layout too comes from the
// core build, never from this file.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { InvokeError, invoke, isLepton } from "../src/core.ts";
import { commandId, decodeReply, encodeRequest, type Reply, type WireLayout } from "../src/wire.ts";

const tool = fileURLToPath(
  new URL("../../../zig/zig-out/bin/lepton-invoke-check", import.meta.url),
);

function readLayout(): WireLayout {
  // The core prints the same object literal it injects into the page.
  const text = execFileSync(tool, ["layout"], { encoding: "utf8" });
  return new Function(`return (${text});`)() as WireLayout;
}

let layout: WireLayout;
let core: ChildProcessWithoutNullStreams;
let pending = Buffer.alloc(0);
const waiting: Array<(frame: Uint8Array) => void> = [];

function ask(frame: Uint8Array): Promise<Reply> {
  const length = Buffer.alloc(4);
  length.writeUInt32LE(frame.byteLength);
  core.stdin.write(Buffer.concat([length, frame]));
  return new Promise((resolve) => {
    waiting.push((reply) => resolve(decodeReply(layout, reply)));
  });
}

before(() => {
  layout = readLayout();
  core = spawn(tool, ["serve"]);
  core.stdout.on("data", (chunk: Buffer) => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.byteLength >= 4) {
      const length = pending.readUInt32LE(0);
      if (pending.byteLength < 4 + length) break;
      const frame = new Uint8Array(pending.subarray(4, 4 + length));
      pending = pending.subarray(4 + length);
      waiting.shift()?.(frame);
    }
  });
});

after(() => {
  core.stdin.end();
});

test("ping echoes its argument under the request's sequence", async () => {
  const id = layout.invoke.commands["core.ping"];
  assert.ok(id !== undefined);
  const args = new TextEncoder().encode("lepton");
  const reply = await ask(encodeRequest(layout, id, 41n, args));
  assert.equal(reply.status, 0);
  assert.equal(reply.sequence, 41n);
  assert.equal(new TextDecoder().decode(reply.result), "lepton");
});

test("core.protocol answers the layout's own protocol version", async () => {
  const id = layout.invoke.commands["core.protocol"];
  assert.ok(id !== undefined);
  const reply = await ask(encodeRequest(layout, id, 2n, new Uint8Array(0)));
  assert.equal(reply.status, 0);
  assert.equal(
    new DataView(reply.result.buffer, reply.result.byteOffset).getUint32(0, true),
    layout.protocol,
  );
});

test("an unknown id gets a named status, not silence", async () => {
  const reply = await ask(encodeRequest(layout, 999, 3n, new Uint8Array(0)));
  assert.equal(layout.invoke.statuses[String(reply.status)], "unknown_command");
});

test("a request frame is not mistaken for a reply", () => {
  // Long enough to pass the size check, so the kind is what refuses it.
  const frame = encodeRequest(layout, 1, 4n, new Uint8Array(32));
  assert.throws(() => decodeReply(layout, frame), /not a reply/);
});

test("a request larger than the core reads is refused before sending", () => {
  const big = new Uint8Array(layout.invoke.maxRequest);
  assert.throws(() => encodeRequest(layout, 1, 5n, big), RangeError);
});

test("outside a Lepton window invoke rejects with status -1", async () => {
  assert.equal(isLepton(), false);
  await assert.rejects(invoke("core.ping"), (error: unknown) => {
    assert.ok(error instanceof InvokeError);
    assert.equal(error.status, -1);
    return true;
  });
});

test("commands.gen.ts is exactly what the core generates", () => {
  const generated = execFileSync(tool, ["types"], { encoding: "utf8" });
  const checkedIn = readFileSync(new URL("../src/commands.gen.ts", import.meta.url), "utf8");
  assert.equal(checkedIn, generated, "run `pnpm run generate` after changing the core's commands");
});

function appCommands(): Record<string, number> {
  const text = execFileSync(tool, ["app-commands"], { encoding: "utf8" });
  return JSON.parse(text) as Record<string, number>;
}

test("an application command answers through the same frame", async () => {
  const id = appCommands()["test.reverse"];
  assert.ok(id !== undefined);
  const reply = await ask(encodeRequest(layout, id, 10n, new TextEncoder().encode("lepton")));
  assert.equal(reply.status, 0);
  assert.equal(new TextDecoder().decode(reply.result), "notpel");
});

test("a registered command missing from permissions is denied", async () => {
  const id = appCommands()["test.ungranted"];
  assert.ok(id !== undefined);
  const reply = await ask(encodeRequest(layout, id, 11n, new Uint8Array(0)));
  assert.equal(layout.invoke.statuses[String(reply.status)], "denied");
});

test("commandId finds built-ins in the layout and app commands beside it", () => {
  const app = appCommands();
  Reflect.set(globalThis, "__lepton", { layout, appCommands: app });
  try {
    assert.equal(commandId("core.ping"), layout.invoke.commands["core.ping"]);
    assert.equal(commandId("test.reverse"), app["test.reverse"]);
    assert.equal(commandId("nope.nothing"), undefined);
  } finally {
    Reflect.deleteProperty(globalThis, "__lepton");
  }
});

test("an application command keeps its bound state between requests", async () => {
  const id = appCommands()["test.count"];
  assert.ok(id !== undefined);
  const first = await ask(encodeRequest(layout, id, 20n, new Uint8Array(0)));
  const second = await ask(encodeRequest(layout, id, 21n, new Uint8Array(0)));
  const read = (reply: Reply): number =>
    new DataView(reply.result.buffer, reply.result.byteOffset).getUint32(0, true);
  assert.equal(read(second), read(first) + 1);
});

test("an InvokeError from another copy of the package is still an InvokeError", async () => {
  // A second module instance, as a linked plugin with its own node_modules loads it.
  // The query makes Node load the file again as a separate module.
  const specifier: string = "../src/core.ts?second-copy";
  const copy = (await import(specifier)) as typeof import("../src/core.ts");
  assert.notEqual(copy.InvokeError, InvokeError, "two distinct classes");
  const foreign = new copy.InvokeError("os.hostname", 4, "denied");
  assert.ok(foreign instanceof InvokeError);
  assert.ok(new InvokeError("core.ping", -1, "no_reply") instanceof copy.InvokeError);
  assert.ok(!(new Error("plain") instanceof InvokeError));
  assert.ok(!({ reason: "denied" } instanceof InvokeError));
});
