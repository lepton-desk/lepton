# @lepton-desk/cli

The Lepton CLI from npm:

```bash
npm create lepton-app@latest        # the guided way
npx @lepton-desk/cli new my-app
npm install -D @lepton-desk/cli && npx lepton dev
```

This package is a 1.6 KB launcher. The CLI itself is a native binary in a platform
package (`@lepton-desk/cli-linux-x64`, `-linux-arm64`, `-win32-x64`, `-darwin-arm64`,
`-darwin-x64`), listed as an optional dependency so the package manager installs only
the one for this machine. There is **no postinstall script and nothing is downloaded**.

- Arguments pass through unchanged; the exit code (or signal) is the binary's.
- `SIGINT`, `SIGTERM` and `SIGHUP` are forwarded, so `timeout 60 npx lepton dev` ends the
  dev server and the window, not only the launcher.
- `LEPTON_BINARY=/path/to/lepton` runs a binary built from source instead.

## Release

```bash
cargo build --release --bin lepton     # on each platform
node packages/cli/scripts/stage.mjs    # copies it into packages/cli-<os>-<arch>/
```

`stage.mjs` refuses a binary whose `--version` differs from this package's version.
