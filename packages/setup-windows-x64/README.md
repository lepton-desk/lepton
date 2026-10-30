# @lepton-desk/setup-windows-x64

Lepton's Windows installer program for x64, built from `zig/src/setup/` in
[lepton-desk/lepton](https://github.com/lepton-desk/lepton) with `zig build setup-exe`.

`lepton package` writes a `setup.exe` as this program followed by the application as a
zip. The program is Win32 only, with no web engine: it installs the application for the
user into `%LOCALAPPDATA%\Programs\<product>`, as the `.msi` does, with a Start menu
shortcut, the same notification identity and link schemes, an entry in Settings → Apps
and an `uninstall.exe`. `setup.exe /S` installs without a window.

```sh
npm install -D @lepton-desk/setup-windows-x64
```

Its version is the CLI's: `lepton package` refuses another. The package has no `os` or
`cpu` field, since a setup.exe is written on Linux too.

The program links the mingw-w64 C runtime's start-up code and Zig's compiler-rt; their
licences are in `THIRD-PARTY.md`.
