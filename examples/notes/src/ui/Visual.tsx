/**
 * The visual editor: Milkdown (ProseMirror) over the note's Markdown, with GitHub tables
 * and task lists.
 *
 * Milkdown prints Markdown in its own style, so its output is never taken as the note:
 * `mergeEdit` writes back only the blocks the user changed, comparing Milkdown's printing
 * now with its printing of the note as opened, and keeps every other block as the note
 * has it. Front matter never reaches Milkdown (it would read `---` as a rule and the keys
 * as a paragraph); it is put back in front of every change.
 */

import { defaultValueCtx, Editor, rootCtx } from "@milkdown/kit/core";
import { history } from "@milkdown/kit/plugin/history";
import { listener, listenerCtx } from "@milkdown/kit/plugin/listener";
import { commonmark } from "@milkdown/kit/preset/commonmark";
import { gfm } from "@milkdown/kit/preset/gfm";
import { getMarkdown } from "@milkdown/kit/utils";
import "@milkdown/kit/prose/view/style/prosemirror.css";
import { type JSX, useEffect, useRef } from "react";
import { parseFrontmatter } from "../notes/links.ts";
import { mergeEdit } from "../notes/merge.ts";

interface Props {
  /** Which note is open; another one builds a new editor. */
  readonly path: string;
  readonly text: string;
  readonly onChange: (text: string) => void;
}

export function Visual({ path, text, onChange }: Props): JSX.Element {
  const host = useRef<HTMLDivElement>(null);
  const changed = useRef(onChange);
  changed.current = onChange;

  // biome-ignore lint/correctness/useExhaustiveDependencies: a new note is a new editor; typing must not rebuild it
  useEffect(() => {
    const root = host.current;
    if (root === null) return;
    const front = parseFrontmatter(text);
    const head = text.slice(0, front.bodyAt);
    const body = front.body;
    // Milkdown's printing of the body as opened: what an untouched block looks like there.
    let baseline: string | null = null;
    let editor: Editor | null = null;
    let gone = false;
    Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, root);
        ctx.set(defaultValueCtx, body);
        ctx.get(listenerCtx).markdownUpdated((_, markdown) => {
          // Back to the baseline (an edit undone) gives the note as opened.
          if (baseline !== null) changed.current(head + mergeEdit(body, baseline, markdown));
        });
      })
      .use(commonmark)
      .use(gfm)
      .use(listener)
      .use(history)
      .create()
      .then((made) => {
        if (gone) {
          made.destroy();
          return;
        }
        editor = made;
        baseline = made.action(getMarkdown());
      });
    return () => {
      gone = true;
      editor?.destroy();
      root.replaceChildren();
    };
  }, [path]);

  return <div className="visual" ref={host} />;
}
