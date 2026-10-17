/**
 * One overlay, three uses: quick switch (Ctrl+O) over note names, the command palette
 * (Ctrl+P), and search across every note (Ctrl+Shift+F). Arrow keys move, Enter runs,
 * Escape closes. In quick switch a name with no match can be made as a new note.
 */

import { type JSX, useEffect, useMemo, useRef, useState } from "react";
import { noteName } from "../notes/links.ts";
import type { SearchHit } from "../notes/vault-index.ts";

export type PaletteMode = "notes" | "commands" | "search";

export interface Command {
  readonly id: string;
  readonly label: string;
  readonly keys?: string;
  readonly run: () => void;
}

interface Props {
  readonly mode: PaletteMode;
  readonly initial?: string;
  readonly findNotes: (query: string) => readonly string[];
  readonly search: (query: string) => readonly SearchHit[];
  readonly commands: readonly Command[];
  readonly onOpen: (path: string, line?: number) => void;
  readonly onCreate: (name: string) => void;
  readonly onClose: () => void;
}

interface Item {
  readonly key: string;
  readonly label: string;
  readonly detail?: string;
  readonly run: () => void;
}

const placeholders: Record<PaletteMode, string> = {
  notes: "Open a note…",
  commands: "Run a command…",
  search: "Search every note…",
};

export function Palette(props: Props): JSX.Element {
  const { mode, findNotes, search, commands, onOpen, onCreate, onClose } = props;
  const [query, setQuery] = useState(props.initial ?? "");
  const [active, setActive] = useState(0);
  const list = useRef<HTMLUListElement>(null);

  const items = useMemo<Item[]>(() => {
    const q = query.trim();
    if (mode === "commands") {
      const lower = q.toLowerCase();
      return commands
        .filter((command) => command.label.toLowerCase().includes(lower))
        .map((command) => ({
          key: command.id,
          label: command.label,
          ...(command.keys === undefined ? {} : { detail: command.keys }),
          run: command.run,
        }));
    }
    if (mode === "search") {
      if (q.length < 2) return [];
      return search(q).map((hit) => ({
        key: `${hit.path}:${hit.lineNumber}`,
        label: hit.line,
        detail: `${noteName(hit.path)} · ${hit.lineNumber}`,
        run: () => onOpen(hit.path, hit.lineNumber),
      }));
    }
    const found: Item[] = findNotes(q).map((path) => ({
      key: path,
      label: noteName(path),
      detail: path,
      run: () => onOpen(path),
    }));
    if (q !== "" && !found.some((item) => item.label.toLowerCase() === q.toLowerCase())) {
      found.push({ key: "+new", label: `Create “${q}”`, run: () => onCreate(q) });
    }
    return found;
  }, [mode, query, commands, findNotes, search, onOpen, onCreate]);

  // A shorter list after typing: the highlighted row stays on the list.
  const current = Math.min(active, Math.max(items.length - 1, 0));
  useEffect(() => {
    list.current?.children[current]?.scrollIntoView({ block: "nearest" });
  }, [current]);

  const run = (item: Item | undefined) => {
    if (item === undefined) return;
    onClose();
    item.run();
  };

  return (
    // biome-ignore lint/a11y/noStaticElementInteractions: a click outside closes; Escape does the same from the field
    // biome-ignore lint/a11y/useKeyWithClickEvents: Escape in the field closes it
    <div className="overlay" onClick={onClose}>
      {/* biome-ignore lint/a11y/useKeyWithClickEvents: keeps a click inside from closing; no key reaches it */}
      <div
        className="palette"
        role="dialog"
        aria-label={placeholders[mode]}
        onClick={(e) => e.stopPropagation()}
      >
        <input
          aria-label={placeholders[mode]}
          placeholder={placeholders[mode]}
          value={query}
          // biome-ignore lint/a11y/noAutofocus: the palette opens to be typed into
          autoFocus
          onChange={(event) => {
            setQuery(event.target.value);
            setActive(0);
          }}
          onKeyDown={(event) => {
            if (event.key === "Escape") onClose();
            else if (event.key === "ArrowDown") {
              event.preventDefault();
              setActive(Math.min(current + 1, items.length - 1));
            } else if (event.key === "ArrowUp") {
              event.preventDefault();
              setActive(Math.max(current - 1, 0));
            } else if (event.key === "Enter") {
              event.preventDefault();
              run(items[current]);
            }
          }}
        />
        <ul className="palette__list" ref={list}>
          {items.map((item, index) => (
            <li key={item.key} data-active={index === current}>
              <button
                type="button"
                tabIndex={-1}
                onMouseMove={() => setActive(index)}
                onClick={() => run(item)}
              >
                <span className="palette__label">{item.label}</span>
                {item.detail !== undefined && (
                  <span className="palette__detail">{item.detail}</span>
                )}
              </button>
            </li>
          ))}
          {items.length === 0 && (
            <li className="muted palette__empty">
              {mode === "search" && query.trim().length < 2
                ? "Type two letters or more."
                : "Nothing found."}
            </li>
          )}
        </ul>
      </div>
    </div>
  );
}
