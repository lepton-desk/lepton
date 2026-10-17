/**
 * Notes: a folder of Markdown files, a tree beside it, one note open in CodeMirror.
 *
 * Saving: `Ctrl+S`, or one second after typing stops. The note on screen is the truth
 * until it is written; switching notes writes it first, so nothing typed is dropped.
 */

import { type JSX, useCallback, useEffect, useRef, useState } from "react";
import { Editor } from "./notes/Editor.tsx";
import { leptonFiles, pickRoot, rememberedRoot } from "./notes/lepton-files.ts";
import { type TreeNode, Vault } from "./notes/vault.ts";

const autosaveMs = 1000;

interface Open {
  readonly path: string;
  /** What the editor holds. */
  readonly text: string;
  /** What is on disk. */
  readonly saved: string;
}

/** An error as one line for the status bar. */
function describe(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

function Tree({
  node,
  openPath,
  onOpen,
}: {
  readonly node: TreeNode;
  readonly openPath: string | null;
  readonly onOpen: (path: string) => void;
}): JSX.Element {
  return (
    <ul className="tree">
      {node.children.map((child) =>
        child.kind === "folder" ? (
          <li key={child.path}>
            <details open>
              <summary className="tree__folder">{child.name}</summary>
              <Tree node={child} openPath={openPath} onOpen={onOpen} />
            </details>
          </li>
        ) : (
          <li key={child.path}>
            <button
              type="button"
              className="tree__note"
              aria-current={child.path === openPath ? "page" : undefined}
              onClick={() => onOpen(child.path)}
            >
              {child.name.replace(/\.md$/i, "")}
            </button>
          </li>
        ),
      )}
    </ul>
  );
}

export function App(): JSX.Element {
  const [vault, setVault] = useState<Vault | null>(null);
  const [tree, setTree] = useState<TreeNode | null>(null);
  const [open, setOpen] = useState<Open | null>(null);
  const [status, setStatus] = useState("");
  const [naming, setNaming] = useState(false);
  // One dialog at a time: clicks while it was open each opened another (four in 0.7 s,
  // measured with dbus-monitor).
  const choosing = useRef(false);
  const [picking, setPicking] = useState(false);
  const openRef = useRef(open);
  openRef.current = open;

  const refresh = useCallback(async (current: Vault) => {
    setTree(await current.tree());
  }, []);

  const openRoot = useCallback(
    async (root: string) => {
      const next = new Vault(root, leptonFiles);
      await refresh(next);
      setVault(next);
      setOpen(null);
      setStatus("");
    },
    [refresh],
  );

  useEffect(() => {
    rememberedRoot()
      .then((root) => (root === null ? undefined : openRoot(root)))
      .catch((error: unknown) =>
        setStatus(`The last folder could not be opened: ${describe(error)}`),
      );
  }, [openRoot]);

  const save = useCallback(async () => {
    const current = openRef.current;
    if (vault === null || current === null || current.text === current.saved) return;
    try {
      await vault.write(current.path, current.text);
      setOpen((now) => (now?.path === current.path ? { ...now, saved: current.text } : now));
      setStatus(`Saved ${current.path}`);
    } catch (error) {
      setStatus(`Not saved: ${describe(error)}`);
    }
  }, [vault]);

  // One second after the last keystroke.
  useEffect(() => {
    if (open === null || open.text === open.saved) return;
    const timer = setTimeout(() => void save(), autosaveMs);
    return () => clearTimeout(timer);
  }, [open, save]);

  const openNote = useCallback(
    async (path: string) => {
      if (vault === null) return;
      await save();
      try {
        const text = await vault.read(path);
        setOpen({ path, text, saved: text });
        setStatus("");
      } catch (error) {
        setStatus(`Could not open ${path}: ${describe(error)}`);
      }
    },
    [vault, save],
  );

  const createNote = useCallback(
    async (name: string) => {
      if (vault === null) return;
      setNaming(false);
      try {
        const path = await vault.create(name.trim(), `# ${name.trim().split("/").pop() ?? ""}\n\n`);
        await refresh(vault);
        await openNote(path);
      } catch (error) {
        setStatus(describe(error));
      }
    },
    [vault, refresh, openNote],
  );

  const choose = useCallback(async () => {
    if (choosing.current) return;
    choosing.current = true;
    setPicking(true);
    try {
      await save();
      const root = await pickRoot();
      if (root !== null) await openRoot(root);
    } catch (error) {
      setStatus(`Could not open the folder: ${describe(error)}`);
    } finally {
      choosing.current = false;
      setPicking(false);
    }
  }, [save, openRoot]);

  if (vault === null || tree === null) {
    return (
      <main className="welcome">
        <h1>Notes</h1>
        <p>Markdown files in a folder you choose. Nothing leaves it.</p>
        <button
          type="button"
          className="button button--primary"
          disabled={picking}
          onClick={() => void choose()}
        >
          {picking ? "Choosing…" : "Choose a folder"}
        </button>
        {status !== "" && <p className="status">{status}</p>}
      </main>
    );
  }

  const dirty = open !== null && open.text !== open.saved;
  return (
    <div className="notes">
      <aside className="sidebar">
        <header className="sidebar__head">
          <button
            type="button"
            className="vault-name"
            disabled={picking}
            onClick={() => void choose()}
            title={vault.root}
          >
            {tree.name}
          </button>
          <button type="button" className="button" onClick={() => setNaming(true)}>
            New note
          </button>
        </header>
        {naming && (
          <form
            className="naming"
            onSubmit={(event) => {
              event.preventDefault();
              const name = new FormData(event.currentTarget).get("name");
              if (typeof name === "string" && name.trim() !== "") void createNote(name);
            }}
          >
            <input
              name="name"
              aria-label="Note name"
              placeholder="Folder/Note name"
              // biome-ignore lint/a11y/noAutofocus: the field exists only because the user asked for it
              autoFocus
              onKeyDown={(event) => event.key === "Escape" && setNaming(false)}
            />
          </form>
        )}
        <nav aria-label="Notes">
          <Tree node={tree} openPath={open?.path ?? null} onOpen={(path) => void openNote(path)} />
        </nav>
      </aside>
      <main className="pane">
        {open === null ? (
          <p className="empty">Choose a note, or make a new one.</p>
        ) : (
          <>
            <header className="pane__head">
              <span className="pane__path">{open.path}</span>
              <span className="pane__state" aria-live="polite">
                {dirty ? "Unsaved" : "Saved"}
              </span>
            </header>
            <Editor
              path={open.path}
              text={open.text}
              onChange={(text) => setOpen((now) => (now === null ? now : { ...now, text }))}
              onSave={() => void save()}
            />
          </>
        )}
        <footer className="status" aria-live="polite">
          {status}
        </footer>
      </main>
    </div>
  );
}
