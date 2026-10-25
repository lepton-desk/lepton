// A native menu's items as the core reads them: the same bytes `menu.zig`'s own test
// builds by hand, so the two ends agree.
import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeMenu } from "../src/payloads.ts";

test("menu items are encoded as the core reads them", () => {
  const bytes = encodeMenu([
    { id: 7, label: "Kopyala" },
    { separator: true },
    { id: 9, label: "Satır sonu: ✓", disabled: true, checked: true },
  ]);
  const label = [...new TextEncoder().encode("Satır sonu: ✓")];
  assert.deepEqual(
    [...bytes],
    [
      3,
      ...[7, 0, 0, 7, 0, ...new TextEncoder().encode("Kopyala")],
      ...[0, 0, 1, 0, 0],
      ...[9, 0, 6, label.length, 0, ...label],
    ],
  );
});

test("a menu the core would refuse is refused here first", () => {
  assert.throws(() => encodeMenu([]), RangeError);
  assert.throws(() => encodeMenu([{ id: 0, label: "kimliksiz" }]), RangeError);
  assert.throws(() => encodeMenu([{ id: 70000, label: "büyük" }]), RangeError);
  assert.throws(() => encodeMenu([{ id: 1, label: "" }]), RangeError);
  assert.throws(() => encodeMenu([{ id: 1, label: "x".repeat(257) }]), RangeError);
});
