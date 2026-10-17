/**
 * The vault: one folder the user picked, its Markdown notes and subfolders.
 *
 * Every path the rest of the app holds is relative to the vault and uses `/`. `resolve`
 * turns it into the absolute path the files layer takes, and refuses one that would leave
 * the vault (`..`, an absolute path): the core's scope would refuse it too, but a wrong
 * path should fail here, with the note's name in the message, not as a bare `denied`.
 *
 * The files layer is an interface so the same code runs on `@lepton-desk/plugin-fs` in the
 * app and on Node's `fs` against a real temporary folder in the tests.
 */

export interface FileEntry {
  readonly name: string;
  readonly isFile: boolean;
  readonly isDirectory: boolean;
}

/** The part of `@lepton-desk/plugin-fs` the vault uses, on absolute paths. */
export interface Files {
  readDir(path: string): Promise<readonly FileEntry[]>;
  readTextFile(path: string): Promise<string>;
  writeTextFile(path: string, text: string): Promise<void>;
  mkdir(path: string, recursive: boolean): Promise<void>;
  remove(path: string, recursive: boolean): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  exists(path: string): Promise<boolean>;
}

export interface TreeNode {
  readonly name: string;
  /** Relative to the vault, `/`-separated; `""` for the vault itself. */
  readonly path: string;
  readonly kind: "folder" | "note";
  /** Folders first, then notes, each by name. Empty for a note. */
  readonly children: readonly TreeNode[];
}

export class VaultPathError extends Error {}

/** The notes of a tree already read, depth first: no second walk of the folders. */
export function notesIn(node: TreeNode): string[] {
  if (node.kind === "note") return [node.path];
  return node.children.flatMap(notesIn);
}

const noteExtension = ".md";
/** Folders below the vault's top that the tree reads; deeper ones are not listed. */
const maxDepth = 12;
/** Folders that hold dependencies or build output, never notes. */
const skippedFolders = new Set(["node_modules", "__pycache__"]);

/** Whether `name` is a note file. */
export function isNote(name: string): boolean {
  return name.toLowerCase().endsWith(noteExtension);
}

/** `parent/child` without doubled or trailing slashes. */
export function join(parent: string, child: string): string {
  return parent === "" ? child : `${parent}/${child}`;
}

/** The folder part of a relative path; `""` at the vault's top. */
export function parentOf(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash < 0 ? "" : path.slice(0, slash);
}

/**
 * A relative path checked to stay inside the vault: no empty, `.` or `..` parts, no
 * leading `/`. Backslashes are not separators on Linux, so they stay part of a name.
 */
export function normalize(path: string): string {
  const parts = path.split("/").filter((part) => part !== "");
  if (path.startsWith("/") || parts.some((part) => part === "." || part === "..")) {
    throw new VaultPathError(`"${path}" is not a path inside the vault`);
  }
  return parts.join("/");
}

export class Vault {
  /** The picked folder's absolute path. */
  readonly root: string;
  private readonly files: Files;

  // Fields written out: Node runs the tests by stripping types, which has no
  // parameter properties.
  constructor(root: string, files: Files) {
    this.root = root;
    this.files = files;
  }

  /** The absolute path of a vault-relative one. */
  resolve(path: string): string {
    const relative = normalize(path);
    return relative === "" ? this.root : `${this.root.replace(/\/+$/, "")}/${relative}`;
  }

  /**
   * The folder tree with its notes. Left out: hidden entries (a leading `.`, as `.git` or
   * `.obsidian`), files that are not notes, folders with no note anywhere below them, and
   * folders known to hold none (`node_modules`). Picked on Downloads, the tree once listed
   * every unpacked program; every folder is one call to the core, so it stops at a depth.
   */
  async tree(path = "", depth = 0): Promise<TreeNode> {
    const relative = normalize(path);
    const entries = depth > maxDepth ? [] : await this.files.readDir(this.resolve(relative));
    const folders: TreeNode[] = [];
    const notes: TreeNode[] = [];
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const child = join(relative, entry.name);
      if (entry.isDirectory) {
        if (skippedFolders.has(entry.name)) continue;
        const folder = await this.tree(child, depth + 1);
        if (folder.children.length > 0) folders.push(folder);
      } else if (entry.isFile && isNote(entry.name)) {
        notes.push({ name: entry.name, path: child, kind: "note", children: [] });
      }
    }
    const byName = (a: TreeNode, b: TreeNode) => a.name.localeCompare(b.name);
    return {
      name:
        relative === ""
          ? (this.root.split("/").filter(Boolean).pop() ?? "")
          : (relative.split("/").pop() ?? ""),
      path: relative,
      kind: "folder",
      children: [...folders.sort(byName), ...notes.sort(byName)],
    };
  }

  /** Every note's path, depth first in tree order. */
  async notePaths(): Promise<string[]> {
    return notesIn(await this.tree());
  }

  async read(path: string): Promise<string> {
    return this.files.readTextFile(this.resolve(path));
  }

  /** Replaces the note's text; the folder must exist. */
  async write(path: string, text: string): Promise<void> {
    return this.files.writeTextFile(this.resolve(path), text);
  }

  /**
   * A new note, with missing folders made. Refuses a name that is taken rather than
   * overwrite it; `.md` is added when the name has no extension.
   */
  async create(path: string, text = ""): Promise<string> {
    let relative = normalize(path);
    if (relative === "") throw new VaultPathError("a note needs a name");
    if (!isNote(relative)) relative += noteExtension;
    if (await this.files.exists(this.resolve(relative))) {
      throw new VaultPathError(`"${relative}" already exists`);
    }
    const folder = parentOf(relative);
    if (folder !== "") await this.files.mkdir(this.resolve(folder), true);
    await this.files.writeTextFile(this.resolve(relative), text);
    return relative;
  }

  async createFolder(path: string): Promise<string> {
    const relative = normalize(path);
    if (relative === "") throw new VaultPathError("a folder needs a name");
    await this.files.mkdir(this.resolve(relative), true);
    return relative;
  }

  /**
   * Moves or renames a note or folder; the target's folder is made if missing. Refuses to
   * replace something already at the target (the core's rename would, silently).
   */
  async move(from: string, to: string): Promise<string> {
    const source = normalize(from);
    const target = normalize(to);
    if (source === "" || target === "")
      throw new VaultPathError("the vault itself cannot be moved");
    if (target === source) return target;
    if (target.startsWith(`${source}/`))
      throw new VaultPathError(`"${source}" cannot move into itself`);
    if (await this.files.exists(this.resolve(target))) {
      throw new VaultPathError(`"${target}" already exists`);
    }
    const folder = parentOf(target);
    if (folder !== "") await this.files.mkdir(this.resolve(folder), true);
    await this.files.rename(this.resolve(source), this.resolve(target));
    return target;
  }

  /** Removes a note, or a folder with everything in it. */
  async remove(path: string, isFolder: boolean): Promise<void> {
    const relative = normalize(path);
    if (relative === "") throw new VaultPathError("the vault itself cannot be removed");
    await this.files.remove(this.resolve(relative), isFolder);
  }
}
