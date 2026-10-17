import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type Files, normalize, Vault, VaultPathError } from "../src/notes/vault.ts";

// The vault's files layer on Node, against a real folder: the same calls the app makes
// through @lepton-desk/plugin-fs, so the tests exercise real directories, not a stand-in.
const nodeFiles: Files = {
  async readDir(path) {
    const entries = await readdir(path, { withFileTypes: true });
    return entries.map((e) => ({ name: e.name, isFile: e.isFile(), isDirectory: e.isDirectory() }));
  },
  readTextFile: (path) => readFile(path, "utf8"),
  writeTextFile: (path, text) => writeFile(path, text),
  mkdir: async (path, recursive) => {
    await mkdir(path, { recursive });
  },
  remove: (path, recursive) => rm(path, { recursive }),
  rename: (from, to) => rename(from, to),
  exists: (path) =>
    stat(path).then(
      () => true,
      () => false,
    ),
};

async function freshVault(): Promise<Vault> {
  const root = await mkdtemp(join(tmpdir(), "notes-vault-"));
  await mkdir(join(root, "Daily"));
  await mkdir(join(root, ".obsidian"));
  await writeFile(join(root, "Plans.md"), "# Plans\n");
  await writeFile(join(root, "Daily", "2026-10-17.md"), "today\n");
  await writeFile(join(root, "picture.png"), "not a note");
  await writeFile(join(root, ".obsidian", "app.json"), "{}");
  // What a Downloads folder holds: programs with no notes, and a package's own README.
  await mkdir(join(root, "Programs", "tool", "bin"), { recursive: true });
  await writeFile(join(root, "Programs", "tool", "bin", "tool"), "binary");
  await mkdir(join(root, "app", "node_modules", "pkg"), { recursive: true });
  await writeFile(join(root, "app", "node_modules", "pkg", "README.md"), "# pkg\n");
  return new Vault(root, nodeFiles);
}

test("the tree shows folders with notes first, notes only, nothing hidden or noteless", async () => {
  const vault = await freshVault();
  const tree = await vault.tree();
  assert.deepEqual(
    tree.children.map((n) => [n.kind, n.path]),
    [
      ["folder", "Daily"],
      ["note", "Plans.md"],
    ],
  );
  assert.deepEqual(
    tree.children[0]?.children.map((n) => n.path),
    ["Daily/2026-10-17.md"],
  );
  assert.deepEqual(await vault.notePaths(), ["Daily/2026-10-17.md", "Plans.md"]);
});

test("create, write, read, move and remove a note on disk", async () => {
  const vault = await freshVault();
  const path = await vault.create("Projects/Lepton", "# Lepton\n");
  assert.equal(path, "Projects/Lepton.md");
  assert.equal(await readFile(join(vault.root, "Projects", "Lepton.md"), "utf8"), "# Lepton\n");

  await vault.write(path, "# Lepton\nShip 0.1.7.\n");
  assert.equal(await vault.read(path), "# Lepton\nShip 0.1.7.\n");

  await assert.rejects(vault.create("Projects/Lepton.md"), VaultPathError);

  const moved = await vault.move(path, "Archive/2026/Lepton.md");
  assert.equal(await vault.read(moved), "# Lepton\nShip 0.1.7.\n");
  await assert.rejects(vault.read(path));
  await assert.rejects(vault.move("Plans.md", "Daily/2026-10-17.md"), VaultPathError);
  await assert.rejects(vault.move("Archive", "Archive/inner"), VaultPathError);

  await vault.remove("Archive", true);
  assert.deepEqual(await vault.notePaths(), ["Daily/2026-10-17.md", "Plans.md"]);
});

test("a path cannot leave the vault", async () => {
  const vault = await freshVault();
  assert.throws(() => normalize("../outside.md"), VaultPathError);
  assert.throws(() => normalize("/etc/passwd"), VaultPathError);
  assert.throws(() => vault.resolve("Daily/../../x.md"), VaultPathError);
  assert.equal(normalize("Daily//2026-10-17.md"), "Daily/2026-10-17.md");
  await assert.rejects(vault.remove("", true), VaultPathError);
});

test("a note larger than one 64 KiB call reads back whole", async () => {
  // The app's files layer splits these into pieces; here the vault must simply pass the
  // text through unchanged.
  const vault = await freshVault();
  const big = `${"# Big\n"}${"lorem ipsum dolor sit amet ".repeat(4000)}\n`;
  const path = await vault.create("Big", big);
  assert.ok(big.length > 64 * 1024);
  assert.equal(await vault.read(path), big);
});
