/**
 * The right column: the open note's outline and backlinks, and the vault's tags. A
 * heading jumps the editor to its line; a backlink opens that note; a tag lists the
 * notes carrying it.
 */

import { type JSX, useState } from "react";
import type { Heading } from "../notes/helpers.ts";
import { noteName } from "../notes/links.ts";

type Tab = "outline" | "backlinks" | "tags";

interface Props {
  readonly headings: readonly Heading[];
  readonly backlinks: readonly string[];
  readonly tags: readonly { readonly tag: string; readonly count: number }[];
  /** The tag being listed, with its notes. */
  readonly tagged: { readonly tag: string; readonly notes: readonly string[] } | null;
  readonly onHeading: (line: number) => void;
  readonly onOpen: (path: string) => void;
  readonly onTag: (tag: string | null) => void;
}

export function SidePanel(props: Props): JSX.Element {
  const [tab, setTab] = useState<Tab>("outline");
  const shown: Tab = props.tagged !== null ? "tags" : tab;
  const tabs: readonly [Tab, string][] = [
    ["outline", "Outline"],
    ["backlinks", `Backlinks ${props.backlinks.length}`],
    ["tags", "Tags"],
  ];
  return (
    <aside className="side">
      <div className="tabs" role="tablist">
        {tabs.map(([id, label]) => (
          <button
            type="button"
            role="tab"
            key={id}
            aria-selected={shown === id}
            onClick={() => {
              setTab(id);
              if (id !== "tags") props.onTag(null);
            }}
          >
            {label}
          </button>
        ))}
      </div>
      <div className="side__body" role="tabpanel">
        {shown === "outline" &&
          (props.headings.length === 0 ? (
            <p className="muted">No headings.</p>
          ) : (
            <ul className="list">
              {props.headings.map((heading) => (
                <li key={heading.line} style={{ paddingLeft: `${(heading.level - 1) * 0.75}rem` }}>
                  <button type="button" onClick={() => props.onHeading(heading.line)}>
                    {heading.text}
                  </button>
                </li>
              ))}
            </ul>
          ))}
        {shown === "backlinks" &&
          (props.backlinks.length === 0 ? (
            <p className="muted">No note links here.</p>
          ) : (
            <ul className="list">
              {props.backlinks.map((path) => (
                <li key={path}>
                  <button type="button" title={path} onClick={() => props.onOpen(path)}>
                    {noteName(path)}
                  </button>
                </li>
              ))}
            </ul>
          ))}
        {shown === "tags" &&
          (props.tagged !== null ? (
            <>
              <button type="button" className="back" onClick={() => props.onTag(null)}>
                ← #{props.tagged.tag}
              </button>
              <ul className="list">
                {props.tagged.notes.map((path) => (
                  <li key={path}>
                    <button type="button" title={path} onClick={() => props.onOpen(path)}>
                      {noteName(path)}
                    </button>
                  </li>
                ))}
              </ul>
            </>
          ) : props.tags.length === 0 ? (
            <p className="muted">No #tags in this vault.</p>
          ) : (
            <ul className="list">
              {props.tags.map(({ tag, count }) => (
                <li key={tag}>
                  <button type="button" onClick={() => props.onTag(tag)}>
                    #{tag} <span className="muted">{count}</span>
                  </button>
                </li>
              ))}
            </ul>
          ))}
      </div>
    </aside>
  );
}
