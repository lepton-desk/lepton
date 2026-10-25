# Changelog

Every change by version, for people working on Lepton: what moved where, and the
measurement or bug behind it. What an application author needs (what to change in an
app, how to update) is on the site's [Changes](https://lepton-desk.vercel.app/docs/changelog/)
page; the GitHub release of each version has the downloads.

Versions follow [SemVer](https://semver.org). A version is first published as
`X.Y.Z-beta.N` under npm's `beta` tag and then as `X.Y.Z` under `latest`; the last beta
of a version freezes its API, and fixes after it go into `X.Y.Z` and its patches.

## 0.1.9-beta.3 *not released*

The last beta of 0.1.9 and its API freeze. `0.1.9-beta.2` was published only in part, from
Windows (`@lepton-desk/cli-win32-x64`, `api`, `plugin-clipboard`, `plugin-dialog`); every
package moves to beta.3 together, and everything since beta.1 is listed here.

### Added

- `@lepton-desk/api/app` `info()` → `{ name, version, identifier }`, and
  `@lepton-desk/api/window` `title()` / `onTitleChanged()`, for a title bar the page draws
  itself. The core writes them into the page as `__lepton.app`
  (`render/webview/transport.zig` `writeApplication`, shared by WPE, Servo and WebView2;
  JSON-escaped, 256 bytes a field, cut at a character); `Bridge.application` is set by the
  template's `main.zig`. `title()` follows the engines' rule: `document.title`, else
  `window.title`. The version reaches the build as `-Dapp-version` (`window_shape.rs`,
  only for a `build.zig` that takes it). `lepton-invoke-check app …` prints the object for
  the SDK's test.
- Single instance and deep links: a second start hands its arguments to the running copy
  (unix socket on Linux, named pipe on Windows), the page hears `app.opened`;
  `deepLinks` registers schemes (desktop entry; `HKCU\Software\Classes` in the MSI).
  `@lepton-desk/api/app` `launchArgs()`, `onOpened()`; `app.args` in new projects'
  permissions, its bytes masked in recordings.
- `fs.watch` in `plugin-fs`: inotify on Linux; `ReadDirectoryChangesW` on Windows
  (`fs_windows_watch.zig`, overlapped, drained by the plugin's `tick`, repeated
  `MODIFIED` from one write merged).
- The native render path on Windows (`window/windows/`): Vulkan, Direct3D 11 and OpenGL 3.3
  tried in that order, the CPU and GDI last; `LEPTON_GPU=vulkan|d3d11|gl|cpu`. Text by
  DirectWrite.
- `window.frameRate: "unlimited"` (`-Dframe-rate`, `LEPTON_FRAME_RATE`).
- `window.decorations: false`, `dragRegion`, `windowControls`, `popupMenu` (`window.menu`),
  `window.start_drag`: WebView2 and Servo's X11 window (`servo/menu_x11.zig`,
  `_MOTIF_WM_HINTS`, `_NET_WM_MOVERESIZE`). WPE keeps its title bar until Lepton's own WPE
  platform (0.2.0).
- Servo: cursors (`servo/cursor_x11.zig`; the bridge's `cursor` callback,
  `LeptonServoCallbacks` now 64 bytes) and the resize shape over a frameless window's
  edge band.
- Servo is the third engine (`--servo`, `@lepton-desk/servo-linux-x64`, built in the
  `servo-bridge` workflow), with patches carried in `servo/patches/`: `servo-url`
  (an origin for `lepton://`), `servo` (the cookie jar written before the skipped
  shutdown), `servo-script` (top-level `await`, below).
- `document.cookie` on `lepton://` pages (`render/webview/cookie_shim.js`, kept in
  `localStorage`); real cookies on the dev server's page persist (`cookies.sqlite`).
- `src-lepton/icon.svg` in new projects; `bundle.icon` takes `.svg` for Linux packages.
- `--owner` and an identifier of `com.<owner>.<app>`.
- Zig 0.17 builds Lepton as well as 0.16 (`compat.zig`, `zig_017` in
  `build_support.zig`, C headers translated by the build under `src/c/`).
- CI: Rust formatting (`cargo fmt --check`) in `zig.yml`, run on any change under
  `crates/`; a `linux-package` job in `windows.yml` that makes the Windows packages on
  Ubuntu, after which the Windows job installs that MSI, measures it and removes it.

### Changed

- The template's `main.zig` is split: the `--target native` program is
  `src-lepton/native.zig`, a framework file that reads `who` from `main.zig` through
  `@import("root")`. `lepton update` manages it (`Part::Native`; added when missing), and
  `tools/release-version.mjs` keeps it in the template history. `main.zig` was 964 lines.
- `identifier`, `productName`, `channel.name`, `window.title` reach every build as
  `-Didentifier`, `-Dproduct`, `-Dchannel`, `-Dtitle`; `main.zig` reads `who.*`. An
  identifier changed after `lepton new` used to reach the installer but not the program.
- The core answers the application's own page only: a random key per run under
  `/__lepton/<key>/`, written only into the transport of that page.
- Other sites open in the system browser (http, https, mailto only).
- File grants live in the app's state folder; a save dialog grants the file, not its folder.
- The app's own folders are narrowed to 0700 when they exist wider
  (`paths.makeOwnPrivate`: last component only, not through a link, only the user's own).
- Channel names are per user (`.u<uid>`).
- `lepton build --macos` is refused with the reason.
- The CLI picks Zig itself (`LEPTON_ZIG`, else `zig`, `zig-0.17`, `zig-0.16`), and every
  Linux binary links through LLVM and LLD (`throughLld`).

### Fixed

- WPE windows showed `org.webkit.app-<sha256>` in the dock, with no icon: the core now
  calls `g_set_prgname(<identifier>)` before the engine starts
  (`useApplicationDirectories`).
- Packages could carry the previous build's frontend files: `zig build` never removes
  stale files under `zig-out/share/<name>/dist`; the CLI empties it first
  (`launch::clear_installed_frontend`).
- Servo reported `uncaught exception: undefined` for every module with top-level `await`
  and never reported a real rejection there (`ThrowModuleErrorsSync`); patched to
  `ReportModuleErrorsAsync` for a pending evaluation promise.
- The native CPU path's title bar had no title (`chrome.paintTitlebar` leaves the text to
  the caller, which never drew it); the GPU path's showed `productName` instead of the
  window's title.
- Ctrl+C on `lepton dev` left the channel in `/dev/shm`; on `lepton run` it sometimes lost
  the app's line.
- Servo: `localStorage` threw `SecurityError`; `window.resized` never arrived; the close
  button did nothing; the right button never reached the page.
- MSI: another build of the same version was refused with 1638 (ProductCode now derived
  from the contents too, the upgrade row covers its own version).
- Windows notifications carry the app's name and icon (`AppUserModelId` registry key,
  `IconUri`); `webPermissions` reaches `Notification.permission` before the page asks.
- Names in `lepton.config.json` are checked for control characters and path separators,
  and escaped wherever they are written.
- Plugin tests link on glibc 2.44 with Zig 0.16 (`-fllvm -flld` in CI).
- Release builds were made for the building machine's CPU: with no `-Dtarget`, Zig's
  native target uses every extension that CPU has (2253 AVX instructions in a native app
  built on an i3-2120, none with `-Dcpu=baseline`), so a package could stop with "illegal
  instruction" elsewhere. `lepton build` (and `package`, which builds through it) now
  passes `-Dcpu=baseline`.

- A Windows build on Windows was made for that machine's Windows version: Zig's native
  target there names the building machine's version as the oldest, and the standard
  library chooses code by it (`has_unix_sockets` from Windows 10 1803). On the CI
  runner (Windows 11 24H2) the program was 68 096 bytes larger than the same app built
  from Linux; cross-building for `win10_rs4` and `win10_rs3` reproduced both sizes
  exactly. Windows builds now always name their target: `x86_64-windows.win10-gnu` for a
  web view, `x86_64-windows.win7-gnu` for a native app (`Platform::build_target`).
- A web view program says it needs Windows 10 in its PE header: Zig writes 6.0 for every
  Windows program whatever its target (measured from `win7` to `win11_dt`) and has no
  option for it, so the template runs the core's `tools/pe_version.zig` on the linked
  program (OS and subsystem version 10.0; Windows refuses a program newer than itself).
  Native programs keep 6.0. `windows.yml` checks the header.

## 0.1.9-beta.1 *2026-10-19*

- The plugins on Windows: `os`, `fs` (one `NtCreateFile` relative to the scope with
  `OBJ_DONT_REPARSE`; every link out refused), `dialog` (`IFileOpenDialog`,
  `IFileSaveDialog`, shown from a zero-delay `SetTimer`), `clipboard`. Known Folders for
  `$APPDATA` and the rest (`platform/windows/paths.zig`).
- WebView2's `/favicon.ico` request is answered 204.
- Every package moved from beta.0 to beta.1 together: beta.0's Windows binary had gone out
  before the plugins ran there.

## 0.1.9-beta.0 *2026-10-19*

- Windows: WebView2 without `WebView2Loader.dll` (`webview2/runtime.zig`), the bridge
  shared through the engine-neutral request (`render/webview/request.zig`), IPC on
  `Local\` sections (`ipc/shm_windows.zig`), `.zip` and an MSI written without WiX
  (`installer.rs`, `installer_db.rs` on `cfb`; ICE: 0 errors).
- Templates: `astro-ts`/`-js`, `next-ts`/`-js`, `angular-ts`, `preact`, `lit`, and the
  JavaScript variants (`frame_pages.rs` for the frameworks with their own pages).
- `frontend` in `lepton.config.json` (`dist`, `devArgs`); `lepton dev` opens the window
  once the server listens (`dev_ready.rs`).
- The JSON schema for `lepton.config.json`.
- `lepton build --windows` links only Windows DLLs.

## 0.1.8 *2026-10-18*

- `lepton update` also moves the project's `@lepton-desk/*` dependencies to the newest
  release and hands over to the installed CLI; React projects from before 0.1.7 get
  `"jsx"` in `tsconfig.json`.

## 0.1.7 *2026-10-18*

- Coloured, framed step output; tools keep their colours through the pipe.
- `lepton update`: `src-lepton/` files compared with the released templates
  (`assets/history/`), replaced when untouched, three-way merged when edited.
- `lepton replay --page --close`.
- SIGTERM, Ctrl+C and the session ending stop the loop instead of killing the core.
- The page waits for the core to publish instead of reading the ring every 250 ms.
- The window size is read from `lepton.config.json` on every build.
- The shm native path reuses two buffers and waits for the compositor.
- `examples/notes`.
- Arch packages `lepton-desk` and `lepton-desk-bin` (`packaging/aur/`).

## 0.1.6 *2026-10-17*

- `create-lepton-app` reads `lepton info --json` in its current shape again; 0.1.5 of it
  is deprecated.

## 0.1.5 *2026-10-17*

- `lepton record` and `lepton replay` (`render/webview/record.zig`, `replay.zig`,
  `page_replay.zig`); `wire` frames have no implicit padding.
- The app's own systemd scope (`platform/linux/scope.zig`); the window title follows
  `document.title`.
- WPE features: inspector in Debug builds, external links through the `OpenURI` portal,
  `window.open`, downloads, permission requests, notifications (`features.zig`,
  `downloads.zig`, `permissions.zig`).
- One `"lepton"` script in new projects.
- No WPEBackend-fdo needed on the `wpe-platform` path.

## 0.1.4 *2026-10-15*

- `create-lepton-app`.
- npm, pnpm, Yarn and Bun, chosen per project (`package_manager.rs`).
- `lepton new` asks for the render path and plugins; `--plugins`, `--package-manager`,
  `--install`.
- Web data directories created 0700.

## 0.1.3 *2026-10-15*

- `plugin-fs` (`openat2(RESOLVE_BENEATH)` scopes) and `plugin-dialog` (xdg-desktop-portal).
- Plugin settings (`plugins.<name>` → `-Dplugin-config`); commands that answer later
  (`takeLater`).
- Each application has its own web data directories.

## 0.1.2 *2026-10-15*

- Plugins: npm packages with TypeScript and Zig; `plugin-os`, `plugin-clipboard`.
- `InvokeError` recognised across two copies of `@lepton-desk/api`.

## 0.1.1 *2026-10-15*

- New projects depend on the published `@lepton-desk/api` and `@lepton-desk/cli`.
- A `commands` build step writes `src/lepton-commands.d.ts` before the frontend's type
  check.

## 0.1.0 *2026-10-15*

- First release, Linux: Wayland and X11 windows, WPE WebKit (`wpe-platform`, 2.54+), the
  native GLES path with an shm fallback, shared-memory IPC, binary `invoke`, events,
  `permissions`, `lepton new | dev | run | build | package` (`.tar.gz`, `.pkg.tar.zst`,
  `.deb`, reproducible, `--verify`), seven templates.
