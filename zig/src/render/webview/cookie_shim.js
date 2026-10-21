// `document.cookie` for the application's own page on `lepton://` (transport.zig puts this
// in the transport, which runs in that page only).
//
// WPE WebKit and Servo keep no cookies for a document whose scheme is not http(s), ftp or
// file: the HTML standard calls it "cookie-averse" (`Document::isCookieAverse` in WebKit,
// `is_cookie_averse` in Servo), so reading gives "" and writing is dropped (measured on
// both). On Windows the page is served from http://lepton.localhost and has real cookies,
// as does a page from the dev server; this is not installed there.
//
// The cookies live in `localStorage` under one key, so they last as long as the page's
// storage does. RFC 6265's rules for a script's cookies: `Max-Age` before `Expires`, a
// past date or `Max-Age=0` deletes, `Path` defaults to the page's directory and is matched
// as a prefix at a `/`, a `Domain` other than the page's host or an `HttpOnly` cookie is
// refused. `Secure` and `SameSite` change nothing here: the page is on localhost.
((globalObject) => {
  "use strict";
  const location = globalObject.location;
  if (/^(https?|ftp|file):$/.test(location.protocol)) return;
  const storage = globalObject.localStorage;
  const key = "__lepton.cookies";
  const maxBytes = 4096;

  const load = () => {
    let jar;
    try {
      jar = JSON.parse(storage.getItem(key) ?? "[]");
    } catch {
      jar = [];
    }
    if (!Array.isArray(jar)) jar = [];
    const now = Date.now();
    return jar.filter((cookie) => cookie !== null && typeof cookie === "object" && (cookie.expires === null || cookie.expires > now));
  };
  const save = (jar) => {
    try {
      storage.setItem(key, JSON.stringify(jar));
    } catch {
      // Storage full or refused: the cookie is dropped, as a browser drops one over its limits.
    }
  };
  const directory = (path) => {
    const slash = path.lastIndexOf("/");
    return slash <= 0 ? "/" : path.slice(0, slash);
  };
  const pathMatches = (requestPath, cookiePath) =>
    requestPath === cookiePath ||
    (requestPath.startsWith(cookiePath) && (cookiePath.endsWith("/") || requestPath[cookiePath.length] === "/"));

  const read = () => {
    const path = location.pathname || "/";
    return load()
      .filter((cookie) => pathMatches(path, cookie.path))
      .sort((a, b) => b.path.length - a.path.length || a.created - b.created)
      .map((cookie) => (cookie.name === "" ? cookie.value : cookie.name + "=" + cookie.value))
      .join("; ");
  };

  const write = (text) => {
    const [pair, ...attributes] = String(text).split(";");
    // Control characters other than tab make the whole cookie invalid.
    if (/[\x00-\x08\x0a-\x1f\x7f]/.test(String(text))) return;
    const equals = pair.indexOf("=");
    const name = (equals < 0 ? "" : pair.slice(0, equals)).trim();
    const value = (equals < 0 ? pair : pair.slice(equals + 1)).trim();
    if (name === "" && value === "") return;
    if (name.length + value.length > maxBytes) return;
    let maxAge = null;
    let expires = null;
    let path = null;
    for (const attribute of attributes) {
      const at = attribute.indexOf("=");
      const attributeName = (at < 0 ? attribute : attribute.slice(0, at)).trim().toLowerCase();
      const argument = at < 0 ? "" : attribute.slice(at + 1).trim();
      if (attributeName === "max-age") {
        if (/^-?[0-9]+$/.test(argument)) maxAge = Number(argument);
      } else if (attributeName === "expires") {
        const date = Date.parse(argument);
        if (!Number.isNaN(date)) expires = date;
      } else if (attributeName === "path") {
        path = argument.startsWith("/") ? argument : null;
      } else if (attributeName === "domain") {
        const domain = argument.replace(/^\./, "").toLowerCase();
        if (domain !== "" && domain !== location.hostname.toLowerCase()) return;
      } else if (attributeName === "httponly") {
        // A script may not set an HttpOnly cookie.
        return;
      }
    }
    const until = maxAge !== null ? (maxAge <= 0 ? 0 : Date.now() + maxAge * 1000) : expires;
    const cookiePath = path ?? directory(location.pathname || "/");
    const jar = load();
    const same = jar.findIndex((cookie) => cookie.name === name && cookie.path === cookiePath);
    const live = until === null || until > Date.now();
    if (same < 0) {
      if (live) jar.push({ name, value, path: cookiePath, expires: until, created: Date.now() });
    } else if (live) {
      // Replaced in place: a cookie keeps its creation order, which reading sorts by.
      jar[same] = { ...jar[same], value, expires: until };
    } else {
      jar.splice(same, 1);
    }
    save(jar);
  };

  Object.defineProperty(globalObject.Document.prototype, "cookie", {
    configurable: true,
    enumerable: true,
    get: read,
    set: write,
  });
})(globalThis);
