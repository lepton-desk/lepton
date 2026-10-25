// The default context menu, drawn into the page by the core (`context_menu_wpe.zig`) in
// an isolated script world: the page's own scripts can neither call the handler that
// carries the choice back nor see the menu's closed shadow root. Evaluated as an
// expression and called with the point (CSS pixels) and the items, `[id, enabled, label]`
// (id 0 a separator); the chosen id goes to `leptonMenu`, the core performs it.
//
// A press on the menu is cancelled, so the field the menu was opened over keeps its
// focus and its selection: Cut, Copy and Paste act on them.
((x, y, items) => {
  const previous = globalThis.__leptonMenuClose;
  if (previous) previous();

  const host = document.createElement("lepton-context-menu");
  host.setAttribute("popover", "manual");
  host.style.cssText =
    "all:initial;position:fixed;inset:auto;margin:0;padding:0;border:0;background:transparent;overflow:visible;";
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `<style>
:host { color-scheme: light dark; }
.menu { min-width: 180px; padding: 4px; box-sizing: border-box; border-radius: 8px;
  font: 13px/1.2 system-ui, sans-serif; background: #ffffff; color: #1f2328;
  border: 1px solid #d0d7de; box-shadow: 0 6px 24px rgb(0 0 0 / 0.18); user-select: none;
  outline: none; }
.item { padding: 6px 10px;
  border-radius: 5px; cursor: default; }
.item.current { background: #e7ecf2; }
.item.disabled { color: #8c959f; }
.rule { height: 1px; margin: 4px 6px; background: #d8dee4; }
@media (prefers-color-scheme: dark) {
  .menu { background: #24282d; color: #e6e8eb; border-color: #3a3f45; box-shadow: 0 6px 24px rgb(0 0 0 / 0.5); }
  .item.current { background: #353b42; }
  .item.disabled { color: #6b737c; }
  .rule { background: #3a3f45; }
}
</style><div class="menu" role="menu"></div>`;
  const menu = root.querySelector(".menu");

  const rows = [];
  for (const [id, enabled, text] of items) {
    if (id === 0) {
      const rule = document.createElement("div");
      rule.className = "rule";
      rule.setAttribute("role", "separator");
      menu.append(rule);
      continue;
    }
    const row = document.createElement("div");
    row.className = enabled ? "item" : "item disabled";
    row.setAttribute("role", "menuitem");
    if (!enabled) row.setAttribute("aria-disabled", "true");
    row.textContent = text;
    menu.append(row);
    rows.push({ id, enabled, row });
  }

  let current = -1;
  const mark = (index) => {
    if (current >= 0) rows[current].row.classList.remove("current");
    current = index;
    if (current >= 0) rows[current].row.classList.add("current");
  };
  const move = (step) => {
    const usable = rows.map((entry, index) => (entry.enabled ? index : -1)).filter((i) => i >= 0);
    if (usable.length === 0) return;
    const at = usable.indexOf(current);
    const next = at < 0 ? (step > 0 ? 0 : usable.length - 1) : (at + step + usable.length) % usable.length;
    mark(usable[next]);
  };

  const listeners = [];
  const on = (target, type, handler) => {
    target.addEventListener(type, handler, true);
    listeners.push([target, type, handler]);
  };
  const close = () => {
    for (const [target, type, handler] of listeners) target.removeEventListener(type, handler, true);
    if (globalThis.__leptonMenuClose === close) globalThis.__leptonMenuClose = undefined;
    host.remove();
  };
  const choose = (entry) => {
    if (!entry?.enabled) return;
    close();
    globalThis.webkit.messageHandlers.leptonMenu.postMessage(entry.id);
  };
  globalThis.__leptonMenuClose = close;

  rows.forEach((entry, index) => {
    entry.row.addEventListener("pointermove", () => mark(entry.enabled ? index : -1));
    entry.row.addEventListener("click", () => choose(entry));
  });
  menu.addEventListener("pointerleave", () => mark(-1));
  // Kept off the page: the field keeps its focus and selection, and nothing under the
  // menu sees the press.
  menu.addEventListener("pointerdown", (event) => event.preventDefault());
  menu.addEventListener("mousedown", (event) => event.preventDefault());

  on(globalThis, "pointerdown", (event) => {
    if (!event.composedPath().includes(host)) close();
  });
  on(globalThis, "keydown", (event) => {
    const handled = { Escape: true, ArrowDown: true, ArrowUp: true, Home: true, End: true, Enter: true, " ": true };
    if (!handled[event.key]) {
      close();
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.key === "Escape") close();
    else if (event.key === "ArrowDown") move(1);
    else if (event.key === "ArrowUp") move(-1);
    else if (event.key === "Home") { mark(-1); move(1); }
    else if (event.key === "End") { mark(-1); move(-1); }
    else choose(rows[current]);
  });
  on(globalThis, "blur", close);
  on(globalThis, "resize", close);
  on(globalThis, "scroll", close);

  document.documentElement.append(host);
  host.showPopover();
  const width = menu.offsetWidth;
  const height = menu.offsetHeight;
  const left = Math.max(0, Math.min(x, innerWidth - width));
  const top = y + height <= innerHeight ? y : Math.max(0, y - height);
  host.style.left = `${left}px`;
  host.style.top = `${top}px`;
})
