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
 *   node tools/transpile-assets.mjs <path-to-typescript>
 *
 * Exits non-zero if any output differs from what is on disk, which is what makes it
 * usable as a check as well as a generator.
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const assets = resolve(here, "..", "crates", "template_injector", "assets");
const generated = resolve(assets, "js");

/** Every source with a JavaScript form, and where that form goes. */
const SOURCES = [
  { from: "lepton.ts", to: "lepton.js" },
  { from: "measures.ts", to: "measures.js" },
  { from: "main.ts", to: "main.js" },
  { from: join("react", "App.tsx"), to: join("react", "App.jsx") },
  { from: join("react", "main.tsx"), to: join("react", "main.jsx") },
];

/** The banner every generated file carries.
 *
 * Present in the output rather than only here because a developer opening
 * `src/lepton.js` in a JavaScript project deserves to know it is generated and from
 * where — otherwise the obvious thing to do is edit it, and the edit vanishes the next
 * time this runs.
 */
function banner(source) {
  return [
    "// Generated from `" + source.replaceAll("\\", "/") + "` by tools/transpile-assets.mjs.",
    "//",
    "// Edit the TypeScript source, not this file: this one is rewritten on every run and",
    "// an edit made here is lost without warning. Running the script in check mode is what",
    "// keeps the two in step.",
    "",
    "",
  ].join("\n");
}

function main() {
  const tscPath = process.argv[2];
  if (tscPath === undefined) {
    process.stderr.write("usage: transpile-assets.mjs <path-to-typescript>\n");
    process.exit(2);
  }

  const require = createRequire(import.meta.url);
  const ts = require(tscPath);

  const check = process.argv.includes("--check");
  let drifted = 0;

  for (const { from, to } of SOURCES) {
    const inputPath = join(assets, from);
    const outputPath = join(generated, to);
    const source = readFileSync(inputPath, "utf8");

    const transpiled = ts.transpileModule(source, {
      fileName: inputPath,
      // `.tsx` and `.jsx` are JSX-bearing, so the compiler has to be told which; a `.ts`
      // file with the same shape of code is not the same language.
      compilerOptions: {
        target: ts.ScriptTarget.ES2022,
        module: ts.ModuleKind.ESNext,
        jsx: ts.JsxEmit.ReactJSX,
        // Names go out as written. Shortening them would make the generated file harder
        // to read against its source, and the point of it is to be read.
        removeComments: false,
        newLine: ts.NewLineKind.LineFeed,
      },
    });

    // The compiler leaves import specifiers exactly as written, so a `./lepton.ts` in
    // the source would become a `./lepton.ts` in the JavaScript — pointing at a file the
    // JavaScript variant does not contain, since it ships `./lepton.js`. Rewritten here
    // because the generator is the only place that knows both halves of the pair.
    const output = transpiled.outputText
      .replace(/\.ts"/g, '.js"')
      .replace(/\.tsx"/g, '.jsx"');

    const contents = banner(from) + output;

    if (check) {
      let existing = null;
      try {
        existing = readFileSync(outputPath, "utf8");
      } catch {
        // A missing file is drift: the generated form is not on disk yet.
      }
      if (existing !== contents) {
        process.stderr.write(`stale or missing: ${outputPath}\n`);
        drifted += 1;
      }
      continue;
    }

    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, contents);
  }

  if (check) {
    if (drifted !== 0) {
      process.stderr.write(
        `${drifted} generated file(s) differ from their source; run node tools/transpile-assets.mjs <typescript>\n`,
      );
      process.exit(1);
    }
    process.stdout.write("generated files match their sources\n");
    return;
  }

  process.stdout.write(`wrote ${SOURCES.length} file(s) to ${generated}\n`);
}

main();