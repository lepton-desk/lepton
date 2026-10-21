// The cookie shim (cookie_shim.js) against RFC 6265's rules for a script's cookies, in a
// stand-in page: `node --test zig/src/render/webview/cookie_shim.test.mjs`.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { test } from "node:test";

const source = readFileSync(new URL("./cookie_shim.js", import.meta.url), "utf8");
const make = (href) => {
  const url = new URL(href);
  const data = new Map();
  class Document {}
  const g = {
    location: { protocol: url.protocol, pathname: url.pathname, hostname: url.hostname },
    localStorage: { getItem: (k) => data.get(k) ?? null, setItem: (k, v) => data.set(k, String(v)) },
    Document,
  };
  new Function("globalThis", source)(g);
  return { doc: new Document(), g, data };
};
test("an http(s) page keeps the engine's own cookies", () => {
  assert.equal(Object.getOwnPropertyDescriptor(make("http://127.0.0.1:5173/").g.Document.prototype, "cookie"), undefined);
});

test("a lepton:// page reads and writes cookies by RFC 6265", () => {
const { doc, g, data } = make("lepton://localhost/");
assert.equal(doc.cookie, "");
doc.cookie = "a=1";
doc.cookie = "b=2; Max-Age=60; Path=/";
assert.equal(doc.cookie, "a=1; b=2");
doc.cookie = "a=3";                      // replaces
assert.equal(doc.cookie, "a=3; b=2");
doc.cookie = "b=; Max-Age=0";            // deletes
assert.equal(doc.cookie, "a=3");
doc.cookie = "c=4; Expires=Thu, 01 Jan 1970 00:00:00 GMT"; // past: not stored
assert.equal(doc.cookie, "a=3");
doc.cookie = "d=5; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=60"; // Max-Age wins
assert.equal(doc.cookie, "a=3; d=5");
doc.cookie = "e=6; HttpOnly";            // refused
doc.cookie = "f=7; Domain=example.com";  // refused
doc.cookie = "g=8; Domain=localhost";    // fine
doc.cookie = "h=9; Path=/deep";          // not visible at /
doc.cookie = "bad=\u0001";               // control character
assert.equal(doc.cookie, "a=3; d=5; g=8");
g.location.pathname = "/deep/page";
assert.equal(doc.cookie, "h=9; a=3; d=5; g=8"); // longer path first
g.location.pathname = "/deeper";
assert.ok(!doc.cookie.includes("h=9"));          // /deep does not match /deeper
// Survives a reload (same storage).
const stored = data.get("__lepton.cookies");
assert.ok(stored.includes("\"a\""));
});
