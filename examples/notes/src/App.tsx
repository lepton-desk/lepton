/**
 * Notes: a folder of Markdown files, a tree beside it, one note open — as source, source
 * with preview, preview, visual (Milkdown) or, for a `board: true` note, a board.
 *
 * Saving: `Ctrl+S`, or one second after typing stops; switching notes writes the open one
 * first. Every note's text is kept for the vault index (backlinks, tags, search) and
 * updated on save. Shortcuts: Ctrl+O open, Ctrl+P commands, Ctrl+Shift+F search,
 * Ctrl+N new note, Ctrl+D today's note, Ctrl+E preview, Ctrl+Shift+E visual.
 */

import { type JSX, lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { isBoard } from "./notes/board.ts";
import { Editor, type Jump } from "./notes/Editor.tsx";
import { baseName, dailyNotePath, outline } from "./notes/helpers.ts";
import {
  copyText,
  forgetRoot,
  leptonFiles,
  loadSettings,
  pickFolder,
  rememberRoot,
  saveAs,
} from "./notes/lepton-files.ts";
import { noteName, parseFrontmatter } from "./notes/links.ts";
import { exportDocument, renderNote } from "./notes/render.ts";
import { join, notesIn, parentOf, type TreeNode, Vault } from "./notes/vault.ts";
import { VaultIndex } from "./notes/vault-index.ts";
import { BoardView } from "./ui/BoardView.tsx";
import { type Command, Palette, type PaletteMode } from "./ui/Palette.tsx";
import { Preview } from "./ui/Preview.tsx";
import { Sidebar } from "./ui/Sidebar.tsx";
import { SidePanel } from "./ui/SidePanel.tsx";

// Milkdown and ProseMirror load when a note is first shown visually, not at start.
const Visual = lazy(() => import("./ui/Visual.tsx").then((module) => ({ default: module.Visual })));

const autosaveMs = 1000;

type Mode = "edit" | "split" | "preview" | "visual" | "board";

interface Open {
  readonly path: string;
  /** What the editor holds. */
  readonly text: string;
  /** What is on disk. */
  readonly saved: string;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** `path` with `from` (a note or folder) replaced by `to`, when it is or lies inside `from`. */
function moved(path: string, from: string, to: string): string {
  if (path === from) return to;
  return path.startsWith(`${from}/`) ? `${to}${path.slice(from.length)}` : path;
}

export function App(): JSX.Element {
  const [vault, setVault] = useState<Vault | null>(null);
  const [recent, setRecent] = useState<readonly string[]>([]);
  const [tree, setTree] = useState<TreeNode | null>(null);
  const [texts, setTexts] = useState<ReadonlyMap<string, string>>(new Map());
  const [open, setOpen] = useState<Open | null>(null);
  const [modes, setModes] = useState<ReadonlyMap<string, Mode>>(new Map());
  const [folder, setFolder] = useState("");
  const [status, setStatus] = useState("");
  const [picking, setPicking] = useState(false);
  const [palette, setPalette] = useState<{ mode: PaletteMode } | null>(null);
  const [naming, setNaming] = useState<"note" | "folder" | null>(null);
  const [tag, setTag] = useState<string | null>(null);
  const [jump, setJump] = useState<Jump | null>(null);
  const openRef = useRef(open);
  openRef.current = open;
  const choosing = useRef(false);

  const index = useMemo(
    () => new VaultIndex([...texts].map(([path, text]) => ({ path, text }))),
    [texts],
  );
  const names = useMemo(() => index.paths.map(noteName), [index]);

  /** The tree and every note's text, read again from disk. */
  const reload = useCallback(async (current: Vault) => {
    // One walk of the folders: the note list comes from the tree just read.
    const next = await current.tree();
    setTree(next);
    const paths = notesIn(next);
    const read = await Promise.all(
      paths.map(async (path) => [path, await current.read(path).catch(() => "")] as const),
    );
    setTexts(new Map(read));
  }, []);

  const openRoot = useCallback(
    async (root: string) => {
      const next = new Vault(root, leptonFiles);
      try {
        await reload(next);
      } catch (error) {
        // A recent vault that moved, or whose grant the core forgot.
        setRecent((await forgetRoot(root)).recent);
        throw error;
      }
      setVault(next);
      setOpen(null);
      setFolder("");
      setTag(null);
      setRecent((await rememberRoot(root)).recent);
      setStatus("");
    },
    [reload],
  );

  useEffect(() => {
    loadSettings()
      .then(async (settings) => {
        setRecent(settings.recent);
        if (settings.root !== null) await openRoot(settings.root);
      })
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
      setTexts((all) => new Map(all).set(current.path, current.text));
      setStatus(`Saved ${current.path}`);
    } catch (error) {
      setStatus(`Not saved: ${describe(error)}`);
    }
  }, [vault]);

  useEffect(() => {
    if (open === null || open.text === open.saved) return;
    const timer = setTimeout(() => void save(), autosaveMs);
    return () => clearTimeout(timer);
  }, [open, save]);

  const openNote = useCallback(
    async (path: string, line?: number) => {
      if (vault === null) return;
      if (openRef.current?.path !== path) {
        await save();
        try {
          const text = await vault.read(path);
          setOpen({ path, text, saved: text });
          setModes((all) =>
            all.has(path) || !isBoard(parseFrontmatter(text).data)
              ? all
              : new Map(all).set(path, "board"),
          );
          setStatus("");
        } catch (error) {
          setStatus(`Could not open ${path}: ${describe(error)}`);
          return;
        }
      }
      if (line !== undefined) setJump({ line, at: Date.now() });
    },
    [vault, save],
  );

  /**
   * A new note. A bare name goes into `into` (the selected folder unless said), a name
   * with a `/` where it says.
   */
  const createNote = useCallback(
    async (name: string, text?: string, into?: string) => {
      if (vault === null) return;
      setNaming(null);
      const trimmed = name.trim();
      const path = trimmed.includes("/") ? trimmed : join(into ?? folder, trimmed);
      try {
        const made = await vault.create(path, text ?? `# ${baseName(trimmed)}\n\n`);
        await reload(vault);
        await openNote(made);
      } catch (error) {
        setStatus(describe(error));
      }
    },
    [vault, folder, reload, openNote],
  );

  const createFolder = useCallback(
    async (name: string) => {
      if (vault === null) return;
      setNaming(null);
      try {
        const made = await vault.createFolder(join(folder, name.trim()));
        setFolder(made);
        // An empty folder is not in the tree until it holds a note.
        setStatus(`Made ${made}: new notes go there`);
      } catch (error) {
        setStatus(describe(error));
      }
    },
    [vault, folder],
  );

  const rename = useCallback(
    async (path: string, to: string) => {
      if (vault === null) return;
      await save();
      const isNoteFile = path.toLowerCase().endsWith(".md");
      const target = isNoteFile && !to.toLowerCase().endsWith(".md") ? `${to}.md` : to;
      try {
        const done = await vault.move(path, target);
        setOpen((now) => (now === null ? now : { ...now, path: moved(now.path, path, done) }));
        setFolder((now) => moved(now, path, done));
        await reload(vault);
        setStatus(`Moved to ${done}`);
      } catch (error) {
        setStatus(describe(error));
      }
    },
    [vault, save, reload],
  );

  const remove = useCallback(
    async (path: string, isFolder: boolean) => {
      if (vault === null) return;
      try {
        await vault.remove(path, isFolder);
        setOpen((now) => (now !== null && moved(now.path, path, "") !== now.path ? null : now));
        setFolder((now) => (moved(now, path, "") !== now ? parentOf(path) : now));
        await reload(vault);
        setStatus(`Deleted ${path}`);
      } catch (error) {
        setStatus(describe(error));
      }
    },
    [vault, reload],
  );

  const choose = useCallback(async () => {
    if (choosing.current) return;
    choosing.current = true;
    setPicking(true);
    try {
      await save();
      const root = await pickFolder();
      if (root !== null) await openRoot(root);
    } catch (error) {
      setStatus(`Could not open the folder: ${describe(error)}`);
    } finally {
      choosing.current = false;
      setPicking(false);
    }
  }, [save, openRoot]);

  const switchVault = useCallback(
    async (root: string) => {
      await save();
      await openRoot(root).catch((error: unknown) =>
        setStatus(`${baseName(root)} could not be opened, so it left the list: ${describe(error)}`),
      );
    },
    [save, openRoot],
  );

  /** Today's note at the vault's top, made on first use. */
  const today = useCallback(async () => {
    const path = dailyNotePath(new Date());
    if (texts.has(path)) await openNote(path);
    else await createNote(path.replace(/\.md$/, ""), `# ${path.replace(/\.md$/, "")}\n\n`, "");
  }, [texts, openNote, createNote]);

  /** A wiki link: the note when it exists, otherwise a new one at the vault's top. */
  const followLink = useCallback(
    async (target: string) => {
      if (texts.has(target)) await openNote(target);
      else await createNote(target, undefined, "");
    },
    [texts, openNote, createNote],
  );

  const mode: Mode = open === null ? "edit" : (modes.get(open.path) ?? "edit");
  const setMode = useCallback((next: Mode) => {
    const path = openRef.current?.path;
    if (path !== undefined) setModes((all) => new Map(all).set(path, next));
  }, []);
  const toggle = useCallback(
    (wanted: Mode) => setMode(mode === wanted ? "edit" : wanted),
    [mode, setMode],
  );

  const copy = useCallback(
    async (as: "markdown" | "html") => {
      const current = openRef.current;
      if (current === null) return;
      try {
        await copyText(as === "markdown" ? current.text : renderNote(current.text, index.paths));
        setStatus(as === "markdown" ? "Copied as Markdown" : "Copied as HTML");
      } catch (error) {
        setStatus(`Not copied: ${describe(error)}`);
      }
    },
    [index],
  );

  const exportHtml = useCallback(async () => {
    const current = openRef.current;
    if (current === null) return;
    const title = noteName(current.path);
    try {
      const html = exportDocument(title, renderNote(current.text, index.paths));
      const path = await saveAs(`${title}.html`, html);
      if (path !== null) setStatus(`Exported to ${path}`);
    } catch (error) {
      setStatus(`Not exported: ${describe(error)}`);
    }
  }, [index]);

  const commands = useMemo<Command[]>(() => {
    const list: Command[] = [
      { id: "new", label: "New note", keys: "Ctrl+N", run: () => setNaming("note") },
      { id: "folder", label: "New folder", run: () => setNaming("folder") },
      { id: "today", label: "Open today's note", keys: "Ctrl+D", run: () => void today() },
      {
        id: "search",
        label: "Search every note",
        keys: "Ctrl+Shift+F",
        run: () => setPalette({ mode: "search" }),
      },
      { id: "vault", label: "Open another folder…", run: () => void choose() },
    ];
    if (open !== null) {
      list.push(
        { id: "preview", label: "Toggle preview", keys: "Ctrl+E", run: () => toggle("preview") },
        { id: "split", label: "Toggle source with preview", run: () => toggle("split") },
        {
          id: "visual",
          label: "Toggle visual editing",
          keys: "Ctrl+Shift+E",
          run: () => toggle("visual"),
        },
        { id: "board", label: "Toggle board view", run: () => toggle("board") },
        { id: "md", label: "Copy note as Markdown", run: () => void copy("markdown") },
        { id: "html", label: "Copy note as HTML", run: () => void copy("html") },
        { id: "export", label: "Export note as HTML…", run: () => void exportHtml() },
      );
    }
    return list;
  }, [open, today, choose, toggle, copy, exportHtml]);

  // Capture phase: the app's shortcuts win over CodeMirror's (Ctrl+D selects the next match there).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.ctrlKey || event.metaKey) || vault === null) return;
      const key = event.key.toLowerCase();
      const run: Record<string, (() => void) | undefined> = event.shiftKey
        ? { f: () => setPalette({ mode: "search" }), e: () => toggle("visual") }
        : {
            o: () => setPalette({ mode: "notes" }),
            p: () => setPalette({ mode: "commands" }),
            n: () => setNaming("note"),
            d: () => void today(),
            e: () => toggle("preview"),
          };
      const action = run[key];
      if (action === undefined) return;
      event.preventDefault();
      event.stopPropagation();
      action();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [vault, today, toggle]);

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
        {recent.length > 0 && (
          <ul className="list welcome__recent">
            {recent.map((root) => (
              <li key={root}>
                <button type="button" title={root} onClick={() => void switchVault(root)}>
                  {baseName(root)} <span className="muted">{root}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {status !== "" && <p className="status">{status}</p>}
      </main>
    );
  }

  const dirty = open !== null && open.text !== open.saved;
  const edit = (text: string) => setOpen((now) => (now === null ? now : { ...now, text }));
  const source = open !== null && (
    <Editor
      path={open.path}
      text={open.text}
      names={names}
      jump={jump}
      onChange={edit}
      onSave={() => void save()}
    />
  );
  const preview = open !== null && (
    <Preview
      text={open.text}
      paths={index.paths}
      onLink={(target) => void followLink(target)}
      onTag={setTag}
    />
  );
  const viewNames: Record<Mode, string> = {
    edit: "Source",
    split: "Split",
    preview: "Preview",
    visual: "Visual",
    board: "Board",
  };

  return (
    <div className="notes">
      <Sidebar
        root={vault.root}
        recent={recent}
        tree={tree}
        openPath={open?.path ?? null}
        selectedFolder={folder}
        picking={picking}
        onOpenNote={(path) => void openNote(path)}
        onSelectFolder={setFolder}
        onSwitchVault={(root) => void switchVault(root)}
        onPickVault={() => void choose()}
        onNewNote={() => setNaming("note")}
        onNewFolder={() => setNaming("folder")}
        onRename={(path, to) => void rename(path, to)}
        onDelete={(path, isFolder) => void remove(path, isFolder)}
      />
      <main className="pane">
        {naming !== null && (
          <form
            className="naming"
            onSubmit={(event) => {
              event.preventDefault();
              const name = new FormData(event.currentTarget).get("name");
              if (typeof name !== "string" || name.trim() === "") return;
              void (naming === "note" ? createNote(name) : createFolder(name));
            }}
          >
            <input
              name="name"
              aria-label={naming === "note" ? "Note name" : "Folder name"}
              placeholder={`${naming === "note" ? "Note" : "Folder"} name, in ${folder === "" ? baseName(vault.root) : folder}`}
              // biome-ignore lint/a11y/noAutofocus: the field exists only because the user asked for it
              autoFocus
              onBlur={() => setNaming(null)}
              onKeyDown={(event) => event.key === "Escape" && setNaming(null)}
            />
          </form>
        )}
        {open === null ? (
          <p className="empty">Choose a note, or press Ctrl+O. Ctrl+P lists every command.</p>
        ) : (
          <>
            <header className="pane__head">
              <span className="pane__path">{open.path}</span>
              <span className="modes">
                {(Object.keys(viewNames) as Mode[]).map((m) => (
                  <button
                    type="button"
                    key={m}
                    aria-pressed={mode === m}
                    onClick={() => setMode(m)}
                  >
                    {viewNames[m]}
                  </button>
                ))}
              </span>
              <span className="pane__state" aria-live="polite">
                {dirty ? "Unsaved" : "Saved"}
              </span>
            </header>
            <div className={`pane__body pane__body--${mode}`}>
              {(mode === "edit" || mode === "split") && source}
              {(mode === "preview" || mode === "split") && preview}
              {mode === "visual" && (
                <Suspense fallback={<p className="empty">Loading the visual editor…</p>}>
                  <Visual path={open.path} text={open.text} onChange={edit} />
                </Suspense>
              )}
              {mode === "board" && <BoardView text={open.text} onChange={edit} />}
            </div>
          </>
        )}
        <footer className="status" aria-live="polite">
          {status}
        </footer>
      </main>
      <SidePanel
        headings={open === null ? [] : outline(open.text)}
        backlinks={open === null ? [] : index.backlinks(open.path)}
        tags={index.tags()}
        tagged={tag === null ? null : { tag, notes: index.notesTagged(tag) }}
        onHeading={(line) => {
          if (mode !== "edit" && mode !== "split") setMode("edit");
          setJump({ line, at: Date.now() });
        }}
        onOpen={(path) => void openNote(path)}
        onTag={setTag}
      />
      {palette !== null && (
        <Palette
          mode={palette.mode}
          findNotes={(q) => index.findNotes(q)}
          search={(q) => index.search(q)}
          commands={commands}
          onOpen={(path, line) => void openNote(path, line)}
          onCreate={(name) => void createNote(name)}
          onClose={() => setPalette(null)}
        />
      )}
    </div>
  );
}
