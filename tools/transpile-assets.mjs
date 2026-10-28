#!/usr/bin/env node
/**
 * Regenerates the JavaScript variants of the injected frontend sources.
 *
 * ## Why this is a script and not five hand-written files
 *
 * The framework injects five sources into every scaffolded project: the channel binding,
 * the shared arithmetic, the plain-DOM screen, and — for React — a component and its
 * entry. Each of them has a TypeScript form, and each needs a JavaScript form, because a
 * project that asked for JavaScript gets `.js` files and a `.js` file containing
 * `import type` does not parse.
 *
 * Written by hand that is eight hundred lines of duplicated logic whose two versions
 * would drift: someone fixes a rounding edge in `measures.ts`, and the JavaScript project
 * keeps the old one and reports a number nobody can explain. The whole point of sharing
 * `measures.ts` between frameworks was to stop arithmetic having two implementations —
 * generating from it stops that from being reintroduced one level down.
 *
 * So: one authoring form, generated output, and a test that regenerates and compares.
 * The output is committed, because the CLI must not need a Node toolchain to scaffold a
 * project — that is the property this framework cares most about.
 *
 * ## Usage
 *
 *   node tools/transpile-assets.mjs [<typescript-package>] [--check]
 *
 * Exits non-zero if any output differs from what is on disk, which is what makes it
 * usable as a check as well as a generator.
 */

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const assets = resolve(root, "crates", "template_injector", "assets");
const generated = resolve(assets, "js");
/** The Biome every new project runs, at the version `BIOME_VERSION` pins. */
const biome = resolve(root, "packages", "api", "node_modules", ".bin", "biome");

/**
 * Every source with a JavaScript form, and where that form goes.
 *
 * JSX is kept as JSX: each framework's Vite plugin compiles its own (React's runtime,
 * Solid's and Preact's are different), so compiling it here once turned react-js's
 * `App.jsx` into `_jsx(...)` calls nobody would write. A `.vue` or `.svelte` file keeps
 * its markup; only its `<script lang="ts">` block is turned into JavaScript.
 */
const SOURCES = [
  { from: "lepton.ts", to: "lepton.js" },
  { from: "measures.ts", to: "measures.js" },
  { from: "main.ts", to: "main.js" },
  { from: join("react", "App.tsx"), to: join("react", "App.jsx") },
  { from: join("react", "main.tsx"), to: join("react", "main.jsx") },
  { from: join("solid", "App.tsx"), to: join("solid", "App.jsx") },
  { from: join("solid", "main.tsx"), to: join("solid", "main.jsx") },
  { from: join("vue", "main.ts"), to: join("vue", "main.js") },
  { from: join("vue", "App.vue"), to: join("vue", "App.vue") },
  { from: join("svelte", "main.ts"), to: join("svelte", "main.js") },
  { from: join("svelte", "App.svelte"), to: join("svelte", "App.svelte") },
  { from: join("preact", "App.tsx"), to: join("preact", "App.jsx") },
  { from: join("preact", "main.tsx"), to: join("preact", "main.jsx") },
  { from: join("lit", "measures-screen.ts"), to: join("lit", "measures-screen.js") },
  { from: join("lit", "main.ts"), to: join("lit", "main.js") },
  { from: join("next", "layout.tsx"), to: join("next", "layout.jsx") },
  { from: join("next", "page.tsx"), to: join("next", "page.jsx") },
  { from: join("next", "Screen.tsx"), to: join("next", "Screen.jsx") },
];

const banner = (source) =>
  [
    `// Generated from \`${source.replaceAll("\\", "/")}\` by tools/transpile-assets.mjs.`,
    "//",
    "// Edit the TypeScript source, not this file: this one is rewritten on every run and",
    "// an edit made here is lost without warning. Running the script in check mode is what",
    "// keeps the two in step.",
    "",
    "",
  ].join("\n");

const markupBanner = (source) =>
  "<!-- Generated from `" +
  source.replaceAll("\\", "/") +
  "` by tools/transpile-assets.mjs; edit the TypeScript source, not this file. -->\n";

/**
 * TypeScript to JavaScript, JSX and every non-type import kept as written.
 *
 * Through TypeScript 7's `tsc`, one file at a time: 7.0 ships no JavaScript API (its
 * announcement: "it does not ship with an API"; 7.1 is to bring a new one), so
 * `ts.transpileModule` is gone and the command line is the stable surface. `--noCheck`
 * emits without type-checking, as `transpileModule` did: the file's imports (React,
 * `./lepton.ts`) are not there to resolve.
 */
function transpile(tsc, source, fileName) {
  const work = mkdtempSync(join(tmpdir(), "lepton-tsc-"));
  try {
    const jsx = fileName.endsWith(".tsx");
    const input = join(work, jsx ? "input.tsx" : "input.ts");
    writeFileSync(input, source);
    const out = join(work, "out");
    execFileSync(
      tsc,
      [
        "--noCheck",
        "--target",
        "es2022",
        "--module",
        "esnext",
        "--jsx",
        "preserve",
        // An import a component's markup uses is not "unused" to TypeScript's eyes only.
        "--verbatimModuleSyntax",
        "--removeComments",
        "false",
        "--newLine",
        "lf",
        "--outDir",
        out,
        input,
      ],
      { cwd: work, stdio: ["ignore", "pipe", "inherit"] },
    );
    const output = readFileSync(join(out, jsx ? "input.jsx" : "input.js"), "utf8");
    // `./lepton.ts` in the source is `./lepton.js` in a JavaScript project.
    return output.replace(/\.ts"/g, '.js"').replace(/\.tsx"/g, '.jsx"');
  } catch (error) {
    throw new Error(`${fileName}: tsc failed (${error.message})`);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

/** JavaScript formatted as the projects' Biome formats it, through its stdin. */
function formatScript(text) {
  return execFileSync(
    biome,
    ["format", "--vcs-enabled=false", `--config-path=${assets}`, "--stdin-file-path=script.js"],
    { input: text, encoding: "utf8" },
  );
}

/**
 * A `.vue` or `.svelte` file with its `<script lang="ts">` block in JavaScript.
 *
 * Biome does not format a component's script block, so the block is formatted on its own
 * and put back at the indent the source gives it (Svelte's is indented, Vue's is not).
 */
function transpileComponent(tsc, source, fileName) {
  const pattern = /(<script\b[^>]*?)\s+lang="ts"([^>]*>)([\s\S]*?)(<\/script>)/;
  const match = source.match(pattern);
  if (match === null) throw new Error(`${fileName}: no <script lang="ts"> block`);
  const [whole, open, close, body, end] = match;
  const indent = (body.split("\n").find((line) => line.trim() !== "") ?? "").match(/^\s*/)[0];
  const script = formatScript(transpile(tsc, body, `${fileName}.ts`))
    .split("\n")
    .map((line) => (line === "" ? line : indent + line))
    .join("\n");
  return source.replace(whole, `${open}${close}\n${script}${end}`);
}

function main() {
  // TypeScript 7's `tsc`: the one `packages/api` installs, unless a package directory
  // is given (`node tools/transpile-assets.mjs <typescript-package> [--check]`).
  const given = process.argv.slice(2).find((argument) => !argument.startsWith("--"));
  const tsc = join(
    given === undefined
      ? resolve(root, "packages", "api", "node_modules", "typescript")
      : resolve(given),
    "bin",
    "tsc",
  );
  const check = process.argv.includes("--check");

  // Written to a staging directory and formatted there with the projects' own Biome
  // settings, so a generated file passes `biome check` in a new project (they did not:
  // four-space indents and unsorted imports, measured on react-js and vanilla-js).
  const staging = mkdtempSync(join(tmpdir(), "lepton-transpile-"));
  try {
    for (const { from, to } of SOURCES) {
      const inputPath = join(assets, from);
      const source = readFileSync(inputPath, "utf8");
      const component = /\.(vue|svelte)$/.test(from);
      const contents = component
        ? markupBanner(from) + transpileComponent(tsc, source, inputPath)
        : banner(from) + transpile(tsc, source, inputPath);
      const stagedPath = join(staging, to);
      mkdirSync(dirname(stagedPath), { recursive: true });
      writeFileSync(stagedPath, contents);
    }
    execFileSync(
      biome,
      ["check", "--write", "--vcs-enabled=false", `--config-path=${assets}`, staging],
      { stdio: ["ignore", "ignore", "inherit"] },
    );

    let drifted = 0;
    for (const { to } of SOURCES) {
      const formatted = readFileSync(join(staging, to), "utf8");
      const outputPath = join(generated, to);
      if (check) {
        let existing = null;
        try {
          existing = readFileSync(outputPath, "utf8");
        } catch {
          // A missing file is drift: the generated form is not on disk yet.
        }
        if (existing !== formatted) {
          process.stderr.write(`stale or missing: ${outputPath}\n`);
          drifted += 1;
        }
        continue;
      }
      mkdirSync(dirname(outputPath), { recursive: true });
      writeFileSync(outputPath, formatted);
    }
    if (check) {
      if (drifted !== 0) {
        process.stderr.write(
          `${drifted} generated file(s) differ from their source; run node tools/transpile-assets.mjs\n`,
        );
        process.exit(1);
      }
      process.stdout.write("generated files match their sources\n");
      return;
    }
    process.stdout.write(`wrote ${SOURCES.length} file(s) to ${generated}\n`);
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

main();
