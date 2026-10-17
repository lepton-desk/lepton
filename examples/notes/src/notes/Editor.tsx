/**
 * The source editor: CodeMirror 6 with Markdown highlighting.
 *
 * One `EditorView` for the component's life. Opening another note replaces the state
 * (a fresh history, so undo never crosses into the previous note) instead of building a
 * new view; edits go up through `onChange`, and `Mod-s` through `onSave`.
 */

import { markdown } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { basicSetup } from "codemirror";
import { type JSX, useEffect, useRef } from "react";

interface Props {
  /** Which note is open; a change loads `text` as a new document. */
  readonly path: string;
  readonly text: string;
  readonly onChange: (text: string) => void;
  readonly onSave: () => void;
}

export function Editor({ path, text, onChange, onSave }: Props): JSX.Element {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  // The latest callbacks, read by the extensions built once per document.
  const handlers = useRef({ onChange, onSave });
  handlers.current = { onChange, onSave };

  // biome-ignore lint/correctness/useExhaustiveDependencies: a new note is a new document; typing must not rebuild it
  useEffect(() => {
    const state = EditorState.create({
      doc: text,
      extensions: [
        basicSetup,
        markdown(),
        EditorView.lineWrapping,
        keymap.of([
          {
            key: "Mod-s",
            preventDefault: true,
            run: () => {
              handlers.current.onSave();
              return true;
            },
          },
        ]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) handlers.current.onChange(update.state.doc.toString());
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

  useEffect(
    () => () => {
      view.current?.destroy();
      view.current = null;
    },
    [],
  );

  return <div className="editor" ref={host} />;
}
