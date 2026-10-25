// `info()` reads the object the core writes into the page: here the core's own
// `writeApplication` output (`lepton-invoke-check app …`), not a hand-written one.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { afterEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { info } from "../src/app.ts";

const tool = fileURLToPath(
  new URL("../../../zig/zig-out/bin/lepton-invoke-check", import.meta.url),
);

function coreApp(...values: [string, string, string]): unknown {
  const text = execFileSync(tool, ["app", ...values], { encoding: "utf8" });
  return new Function(`return (${text});`)();
}

afterEach(() => {
  Reflect.deleteProperty(globalThis, "__lepton");
});

test("info() is who the core says the application is, quotes and all", () => {
  const name = 'Not"lar \\ ğ ';
  Reflect.set(globalThis, "__lepton", { app: coreApp(name, "1.2.3", "dev.lepton.notes") });
  assert.deepEqual(info(), { name, version: "1.2.3", identifier: "dev.lepton.notes" });
  assert.ok(Object.isFrozen(info()));
});

test("info() throws outside a Lepton window and under an older core", () => {
  assert.throws(() => info(), /__lepton\.app/);
  Reflect.set(globalThis, "__lepton", { layout: {} });
  assert.throws(() => info(), /__lepton\.app/);
});
