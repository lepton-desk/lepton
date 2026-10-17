/**
 * The rendered note. `renderNote` turns off the note's own HTML, so the markup set here is
 * markdown-it's and the wiki-link and tag anchors it adds; clicks on those open the note
 * (made if missing) or list the tag. Web links go to the desktop's browser, which the core
 * does for any link leaving the page.
 */

import { type JSX, useMemo } from "react";
import { renderNote } from "../notes/render.ts";

interface Props {
  readonly text: string;
  readonly paths: readonly string[];
  readonly onLink: (target: string) => void;
  readonly onTag: (tag: string) => void;
}

export function Preview({ text, paths, onLink, onTag }: Props): JSX.Element {
  const html = useMemo(() => renderNote(text, paths), [text, paths]);
  return (
    // biome-ignore lint/a11y/useKeyWithClickEvents: delegates to the anchors inside, which take Enter themselves
    <article
      className="preview"
      onClick={(event) => {
        const anchor = (event.target as Element).closest("a");
        if (anchor === null) return;
        const note = anchor.getAttribute("data-note");
        const tag = anchor.getAttribute("data-tag");
        if (note !== null) {
          event.preventDefault();
          onLink(note);
        } else if (tag !== null) {
          event.preventDefault();
          onTag(tag);
        }
      }}
      // biome-ignore lint/security/noDangerouslySetInnerHtml: renderNote escapes the note (markdown-it with html off)
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
