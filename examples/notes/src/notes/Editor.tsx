/**
 * The source editor: CodeMirror 6 with Markdown highlighting.
 *
 * One `EditorView` for the component's life. Opening another note replaces the state
 * (a fresh history, so undo never crosses into the previous note) instead of building a
 * new view; edits go up through `onChange`, and `Mod-s` through `onSave`. Typing `[[`
 * offers the vault's note names; `jump` moves the cursor to a line (the outline).
 */

import { autocompletion, type CompletionContext } from "@codemirror/autocomplete";
import { markdown } from "@codemirror/lang-markdown";
import { EditorSelection, EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { basicSetup } from "codemirror";
import { type JSX, useEffect, useRef } from "react";

export interface Jump {
  readonly line: number;
  /** Changes on every request, so the same line can be asked for twice. */
  readonly at: number;
}

interface Props {
  /** Which note is open; a change loads `text` as a new document. */
  readonly path: string;
  readonly text: string;
  /** Note names offered after `[[`. */
  readonly names: readonly string[];
  readonly jump: Jump | null;
  readonly onChange: (text: string) => void;
  readonly onSave: () => void;
}

export function Editor({ path, text, names, jump, onChange, onSave }: Props): JSX.Element {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  // The latest callbacks and names, read by the extensions built once per document.
  const live = useRef({ onChange, onSave, names });
  live.current = { onChange, onSave, names };

  // biome-ignore lint/correctness/useExhaustiveDependencies: a new note is a new document; typing must not rebuild it
  useEffect(() => {
    const wikiNames = (context: CompletionContext) => {
      const before = context.matchBefore(/\[\[[^\]|\n]*/);
      if (before === null) return null;
      return {
        from: before.from + 2,
        options: live.current.names.map((name) => ({ label: name, apply: `${name}]]` })),
        validFor: /^[^\]|\n]*$/,
      };
    };
    const state = EditorState.create({
      doc: text,
      extensions: [
        basicSetup,
        markdown(),
        EditorView.lineWrapping,
        autocompletion({ override: [wikiNames] }),
        keymap.of([
          {
            key: "Mod-s",
            preventDefault: true,
            run: () => {
              live.current.onSave();
              return true;
            },
          },
        ]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) live.current.onChange(update.state.doc.toString());
        }),
      ],
    });
    if (view.current === null) {
      if (host.current === null) return;
      view.current = new EditorView({ state, parent: host.current });
    } else {
      view.current.setState(state);
    }
    view.current.focus();
  }, [path]);

  useEffect(() => {
    const current = view.current;
    if (current === null || jump === null) return;
    const line = current.state.doc.line(Math.min(Math.max(jump.line, 1), current.state.doc.lines));
    current.dispatch({
      selection: EditorSelection.cursor(line.from),
      effects: EditorView.scrollIntoView(line.from, { y: "start", yMargin: 24 }),
    });
    current.focus();
  }, [jump]);

  useEffect(
    () => () => {
      view.current?.destroy();
      view.current = null;
    },
    [],
  );

  return <div className="editor" ref={host} />;
}
