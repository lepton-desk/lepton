# create-lepton-app

Create a [Lepton](https://github.com/lepton-desk/lepton) desktop app — a Vite frontend in a
native window with a Zig core, no Electron, no WebKitGTK.

```bash
npm create lepton-app@latest
```

```bash
pnpm create lepton-app
```

```bash
yarn create lepton-app
```

```bash
bun create lepton-app
```

The wizard asks for:

- a project name;
- a frontend (vanilla, React, Vue, Svelte or Solid; TypeScript or JavaScript);
- a render path (`webview`, your page in WPE WebKit; or `native`, drawn by the core);
- the plugins to start with: `os`, `clipboard`, `fs`, `dialog`.

Every plugin you choose is added as a dependency, with each of its commands listed under
`permissions` in `lepton.config.json`. `fs` starts with only the app's own data directory
in scope. Nothing is granted that you did not pick.

The project is installed with the package manager you ran the command with. Lepton then
keeps using that one: `lepton dev`, `lepton build` and `lepton run` read the project's
lockfile, so a Yarn project is never built with pnpm. A Yarn project gets
`nodeLinker: node-modules` in `.yarnrc.yml`, because plugins carry Zig sources that the
core compiles from `node_modules`.

## Running it

A project has one script, `"lepton": "lepton"`, so every command runs through it:
`pnpm lepton dev`, `yarn lepton build`, `bun lepton record`, `npm run lepton dev`.
**With npm, put `--` before any flag**: `npm run lepton -- build --release`. npm keeps
flags for itself — an unknown one stops it ("Unknown cli flag"), and one it knows, like
`--json`, it takes silently, so `lepton` never sees it. pnpm, Yarn and Bun pass flags on.

## Without questions

```bash
npm create lepton-app@latest Notes -- --template vue-ts --target webview --plugins fs,dialog --non-interactive
```

Every `lepton new` flag works here. `--no-install` skips the install.

## What is different

- **Nothing is downloaded.** This package depends on `@lepton-desk/cli`, whose native
  binary comes as an optional platform package. There is no postinstall script.
- **The machine is checked first.** `lepton info` runs before anything is written. If Zig
  or WPE WebKit is missing, it says so and still creates the project.
- **Permissions start closed.** A command runs only when it is listed. A plugin is
  granted only when you pick it, and the fs scope is a directory you name.

MIT OR Apache-2.0.
