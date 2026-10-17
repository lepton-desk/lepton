/**
 * The left column: which vault is open (and the others opened before), the folder tree,
 * and what can be done to a folder or note — select, rename or move, delete.
 *
 * A selected folder is where a new note or folder goes. Renaming takes a path, so
 * `Archive/Old plan` both renames and moves. Deleting asks twice in place: WPE draws no
 * `confirm()` dialog.
 */

import { type JSX, useEffect, useState } from "react";
import { baseName } from "../notes/helpers.ts";
import type { TreeNode } from "../notes/vault.ts";

interface Props {
  readonly root: string;
  readonly recent: readonly string[];
  readonly tree: TreeNode;
  readonly openPath: string | null;
  readonly selectedFolder: string;
  readonly picking: boolean;
  readonly onOpenNote: (path: string) => void;
  readonly onSelectFolder: (path: string) => void;
  readonly onSwitchVault: (root: string) => void;
  readonly onPickVault: () => void;
  readonly onNewNote: () => void;
  readonly onNewFolder: () => void;
  readonly onRename: (path: string, to: string) => void;
  readonly onDelete: (path: string, isFolder: boolean) => void;
}

function VaultMenu({
  root,
  recent,
  picking,
  onSwitchVault,
  onPickVault,
}: Pick<Props, "root" | "recent" | "picking" | "onSwitchVault" | "onPickVault">): JSX.Element {
  const [open, setOpen] = useState(false);
  return (
    <div className="vault-menu">
      <button
        type="button"
        className="vault-name"
        aria-expanded={open}
        title={root}
        onClick={() => setOpen((was) => !was)}
      >
        {baseName(root)} <span aria-hidden="true">▾</span>
      </button>
      {open && (
        <div className="menu" role="menu">
          {recent
            .filter((other) => other !== root)
            .map((other) => (
              <button
                type="button"
                role="menuitem"
                key={other}
                title={other}
                onClick={() => {
                  setOpen(false);
                  onSwitchVault(other);
                }}
              >
                {baseName(other)}
                <span className="menu__hint">{other}</span>
              </button>
            ))}
          <button
            type="button"
            role="menuitem"
            disabled={picking}
            onClick={() => {
              setOpen(false);
              onPickVault();
            }}
          >
            {picking ? "Choosing…" : "Open another folder…"}
          </button>
        </div>
      )}
    </div>
  );
}

/** Rename-or-move in place; Escape or leaving the field cancels. */
function RenameField({
  path,
  onDone,
}: {
  readonly path: string;
  readonly onDone: (to: string | null) => void;
}): JSX.Element {
  return (
    // biome-ignore lint/a11y/useKeyWithClickEvents: only stops a click from reaching the folder's <summary>; the field inside takes the keys
    <form
      className="rename"
      // Inside a folder's <summary>: a click here must not fold or select the folder.
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
      }}
      onSubmit={(event) => {
        event.preventDefault();
        const to = new FormData(event.currentTarget).get("to");
        onDone(typeof to === "string" && to.trim() !== "" && to.trim() !== path ? to.trim() : null);
      }}
    >
      <input
        name="to"
        aria-label={`New path for ${path}`}
        defaultValue={path}
        // biome-ignore lint/a11y/noAutofocus: the field exists only because the user asked for it
        autoFocus
        onBlur={() => onDone(null)}
        onKeyDown={(event) => event.key === "Escape" && onDone(null)}
      />
    </form>
  );
}

function Actions({
  path,
  isFolder,
  onRename,
  onDelete,
}: {
  readonly path: string;
  readonly isFolder: boolean;
  readonly onRename: () => void;
  readonly onDelete: (path: string, isFolder: boolean) => void;
}): JSX.Element {
  const [arming, setArming] = useState(false);
  useEffect(() => {
    if (!arming) return;
    const timer = setTimeout(() => setArming(false), 3000);
    return () => clearTimeout(timer);
  }, [arming]);
  return (
    // biome-ignore lint/a11y/useKeyWithClickEvents lint/a11y/noStaticElementInteractions: only stops a click on its buttons from reaching the folder's <summary>
    <span
      className="row__actions"
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
      }}
    >
      <button type="button" title="Rename or move" aria-label={`Rename ${path}`} onClick={onRename}>
        ✎
      </button>
      <button
        type="button"
        className={arming ? "danger" : undefined}
        title={arming ? "Click again to delete" : "Delete"}
        aria-label={arming ? `Really delete ${path}` : `Delete ${path}`}
        onClick={() => (arming ? onDelete(path, isFolder) : setArming(true))}
      >
        {arming ? "Delete?" : "✕"}
      </button>
    </span>
  );
}

function Tree(props: Props & { readonly node: TreeNode }): JSX.Element {
  const { node, openPath, selectedFolder, onOpenNote, onSelectFolder, onRename, onDelete } = props;
  const [renaming, setRenaming] = useState<string | null>(null);
  const finish = (path: string) => (to: string | null) => {
    setRenaming(null);
    if (to !== null) onRename(path, to);
  };
  return (
    <ul className="tree">
      {node.children.map((child) =>
        child.kind === "folder" ? (
          <li key={child.path}>
            <details open>
              {/* biome-ignore lint/a11y/noStaticElementInteractions: <summary> is the folder's own control; clicking it also selects the folder */}
              <summary
                className="row tree__folder"
                data-selected={child.path === selectedFolder}
                onClick={() => onSelectFolder(child.path)}
              >
                {renaming === child.path ? (
                  <RenameField path={child.path} onDone={finish(child.path)} />
                ) : (
                  <>
                    <span className="row__name">{child.name}</span>
                    <Actions
                      path={child.path}
                      isFolder
                      onRename={() => setRenaming(child.path)}
                      onDelete={onDelete}
                    />
                  </>
                )}
              </summary>
              <Tree {...props} node={child} />
            </details>
          </li>
        ) : (
          <li key={child.path} className="row">
            {renaming === child.path ? (
              <RenameField path={child.path} onDone={finish(child.path)} />
            ) : (
              <>
                <button
                  type="button"
                  className="row__name tree__note"
                  aria-current={child.path === openPath ? "page" : undefined}
                  onClick={() => onOpenNote(child.path)}
                >
                  {child.name.replace(/\.md$/i, "")}
                </button>
                <Actions
                  path={child.path}
                  isFolder={false}
                  onRename={() => setRenaming(child.path)}
                  onDelete={onDelete}
                />
              </>
            )}
          </li>
        ),
      )}
    </ul>
  );
}

export function Sidebar(props: Props): JSX.Element {
  const { selectedFolder, onSelectFolder, onNewNote, onNewFolder } = props;
  return (
    <aside className="sidebar">
      <header className="sidebar__head">
        <VaultMenu {...props} />
      </header>
      <div className="sidebar__tools">
        <button type="button" className="button" onClick={onNewNote} title="New note (Ctrl+N)">
          New note
        </button>
        <button type="button" className="button" onClick={onNewFolder}>
          New folder
        </button>
      </div>
      <button
        type="button"
        className="target"
        title="New notes and folders go here"
        onClick={() => onSelectFolder("")}
      >
        in: <strong>{selectedFolder === "" ? baseName(props.root) : selectedFolder}</strong>
      </button>
      <nav aria-label="Notes">
        <Tree {...props} node={props.tree} />
      </nav>
    </aside>
  );
}
