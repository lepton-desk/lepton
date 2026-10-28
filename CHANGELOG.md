# Changelog

Every change by version, for people working on Lepton: what moved where, and the
measurement or bug behind it. What an application author needs (what to change in an
app, how to update) is on the site's [Changes](https://lepton-desk.vercel.app/docs/changelog/)
page; the GitHub release of each version has the downloads.

Versions follow [SemVer](https://semver.org). A version is first published as
`X.Y.Z-beta.N` under npm's `beta` tag and then as `X.Y.Z` under `latest`; the last beta
of a version freezes its API, and fixes after it go into `X.Y.Z` and its patches.

## 0.1.9-beta.3 *not released*

The last beta of 0.1.9 and its API freeze; every package moves to beta.3 together.
`@lepton-desk/api` 0.1.9-beta.2 went out from Windows before `info()` and `title()`, so
both are listed here, though the Linux beta.2 core already answers them.

### Added

- The `appimage` format (`commands/appimage.rs`): the AppDir as a squashfs behind
  AppImage/type2-runtime `20251108`'s `runtime-x86_64`, `<binary>-<version>-x86_64.AppImage`.
  The runtime ships unchanged in the new `@lepton-desk/appimage-runtime-linux-x64` (staged
  by `tools/stage-appimage-runtime.mjs`, its SHA-256 `2fca8b44…ec260d` checked there and by
  `lepton package`; `LICENSE` is the runtime's, `THIRD-PARTY.md` names the libfuse 3.15.0
  and squashfuse 0.5.2 sources). The squashfs is written by `backhand` 0.25 with gzip only
  (`flate2`, no C), root-owned, timed by `SOURCE_DATE_EPOCH`, entries sorted: two runs give
  the same bytes, with and without it (measured). Measured on the probe app: 1 092 088
  bytes; `--appimage-extract` gives the AppDir back exactly; `--verify` runs the file
  (FUSE-mounted, 8 processes, closed in 0.08 s, no process or mount left). The runtime
  needs a setuid-root `fusermount`/`fusermount3` on `PATH` (`runtime.c`). x86-64 only:
  the arm64 runtime is for the arm64 packaging item. `tools/npm-preflight.sh`,
  `release-version.mjs` and `docs/yayin.md` know the package.
- AppStream metainfo in every Linux bundle (`commands/metainfo.rs`):
  `share/metainfo/<identifier>.metainfo.xml` with the required `id`, `name`, `summary`
  (`bundle.description`, else `productName`), `description` (`bundle.longDescription` in
  `<p>` blocks), `metadata_license` (`bundle.metadataLicense`, `CC0-1.0` without it) and
  `launchable`, plus `project_license`, the homepage, the developer
  (`bundle.maintainer`'s name under the identifier's owner), `<provides><binary>` and the
  OARS 1.1 `content_rating` (`bundle.contentRating`, checked against the 22 ids of
  `hughsie/oars` `oars-1.1.rnc`; empty without it). The release is dated by
  `SOURCE_DATE_EPOCH`, else `bundle.releaseDate`; with neither there is none, since
  AppStream refuses an undated release (`release-time-missing`, measured). `lepton package`
  warns then, and when the first paragraph is under 80 characters. `appstreamcli validate`
  (1.2.1) passes with no date, a configured one and `SOURCE_DATE_EPOCH`.
- `bundle.description`, `longDescription`, `license`, `homepage`, `copyright`, `category`
  (`template_injector/src/bundle.rs` `Details`; one line each but `longDescription`, no
  control characters, `homepage` http(s), `category` one of the 13 freedesktop main
  categories). The desktop entry gets `Comment` and `Categories` (`Development` without
  one), Arch `pkgdesc`/`url`/`license`, the `.deb` `Description` with its extended lines
  (` .` for an empty one) and `Homepage`. With `copyright` and `license` the Linux bundle
  carries `share/doc/<package>/copyright` (copyright-format 1.0), and a `.deb` now refuses
  to be written without them, as without a maintainer. The schema follows (ajv: the six
  accepted, five bad values refused).
- `lepton icon [source]` (`commands/icon.rs`): one square SVG, or a square PNG of at
  least 512 px, drawn by `resvg` (pure Rust, system fonts for lettering) into
  `src-lepton/icons/`: `<n>x<n>.png` for 16–512, `icon.ico` (PNG entries, 16–256, written
  without an encoder crate) and the SVG. A large PNG is halved step by step before the
  last scale. Same source, same bytes (tested). Linux bundles install the PNGs under
  `share/icons/hicolor/<n>x<n>/apps/<identifier>.png` (`package_tree.rs`): those files
  when the project has them (a partial set is refused), else drawn from the project's SVG
  while packaging. Its `icon.ico` is the Windows program's (`-Dicon`) and the MSI's when
  `bundle.icon` names none.
- `@lepton-desk/api/app` `info()` → `{ name, version, identifier }`, written into the page
  by the core as `__lepton.app` (`render/webview/transport.zig` `writeApplication`, shared
  by WPE, Servo and WebView2; JSON-escaped, 256 bytes a field, cut at a character);
  `Bridge.application` is set by the template's `main.zig`. The version reaches the build as
  `-Dapp-version` (`window_shape.rs`, only for a `build.zig` that takes it).
  `lepton-invoke-check app …` prints the object for the SDK's test.
- The window's name is the core's: the `window.title` command answers it and the
  `window.title` event reports a change (`Bridge.showTitle`, called by each engine with
  what its window shows — the page's `document.title`, else `window.title`). The SDK's
  `title()` and `onTitleChanged()` read them, so a title bar the page draws needs no DOM
  watching, and 0.2.0's native apps can give the same (`docs/plans/uyumluluk-0.2.0.md`).
- `lepton package --linux --servo`: the core is built with `-Dservo-bundle`, which installs
  `liblepton_servo.so` into `zig-out/lib/<name>/` and gives the binary only
  `$ORIGIN/../lib/<name>` as its run path (`build_servo.zig`; the template sets
  `each_lib_rpath = false`, since Zig otherwise appended the `-L` directory — measured).
  `servo.rs` `carry` copies it into the bundle; `/usr/lib/<name>/` in the Arch and Debian
  packages, so two apps never own the same file. The package's dependencies are the
  binary's and the carried library's `DT_NEEDED` less the carried ones
  (`depends::needed_from_system`), plus `libEGL.so.1`, which Servo opens at run time
  (`servo::LOADED`, measured with `LD_DEBUG=files`): fontconfig, libstdc++, libgcc, zlib
  and libglvnd come from Servo. Every Linux package refuses a binary whose run path names an absolute directory:
  before, a `--servo` binary carried the developer's `node_modules` path and found Servo
  only on the machine that built it (measured on a beta.2 project). A `build.zig` without
  `servo-bundle` is refused with `lepton update`. Measured: `--verify` of the `.tar.gz`
  and the Arch package (45.2 / 61.0 MB), `LD_DEBUG` shows the library loaded from the
  unpacked package.
- A default right-click menu on every engine (`render/webview/context_menu.zig`): Cut,
  Copy, Paste, Select All, disabled where they would do nothing, and Inspect in a Debug
  build, wherever the page did not cancel `contextmenu`. `window.contextMenu: false`
  (`-Dcontext-menu=false`, `window_shape.rs`) turns it off. WPE emits `context-menu` and
  draws nothing, and its Wayland surfaces are its own: the menu is drawn into the page
  (`context_menu.js`) in the `lepton-menu` script world, where alone the `leptonMenu`
  handler exists, in a closed shadow root in the top layer; a press on it is cancelled so
  the field keeps its focus and selection, and the choice is
  `webkit_web_view_execute_editing_command` (`context_menu_wpe.zig`). Measured on WPE
  2.54: the signal, the call with the right enabled states, and the choice reaching the
  core; the user confirmed the enabled items work. Servo: the bridge takes Servo's own
  `EmbedderControl::ContextMenu`, asks the page for a selection outside a text field,
  calls the core's new `context_menu` callback (`LeptonServoCallbacks` now 72 bytes), which
  draws the list in `menu_x11.zig`; `lepton_servo_context_menu_select` answers. WebView2:
  its own menu, kept to the editing items (`webview2/context_menu.zig`); before, release
  builds had none and Debug builds a browser's. Labels are Turkish for a `tr` locale.
- `wasm.threads` (`lepton.config.json`, default off): WebAssembly threads in the page.
  The core sends `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp` on its answers (`respond_wpe.zig`,
  `webview2/request.zig`, `render/webview/wasm_threads.zig`) and, on WPE, sets
  `JSC_useSharedArrayBuffer=1` before the web process starts: WPE 2.54.2 has no
  `SharedArrayBuffer` with the headers alone, and the option is JavaScriptCore-wide, not
  per origin. `-Dwasm-threads=true` (`window_shape.rs`; an older `build.zig` is warned
  about, not refused). Under `lepton dev` the page comes from the dev server, so every
  template's dev configuration reads `wasm.threads` itself (Vite and Astro
  `server.headers`, Next.js `headers()` for `next dev` only, a new `vite.config` for Lit);
  Angular's `angular.json` cannot, so its `frontend.devArgs` carry `{isolation}`, which
  `lepton dev` makes `--headers …` (`frontend::ISOLATION`). `lepton update` replaces a dev
  configuration still as released (`dev_headers.rs`, `assets/history/dev-config/`), shows
  the lines for an edited one, and adds `{isolation}` to an Angular project's flags.
  Measured on WPE 2.54.2: on, `crossOriginIsolated` true, a shared `WebAssembly.Memory`, a
  worker reading 41 and writing 42 through it; off, no `SharedArrayBuffer`. WebView2 (CI,
  `tools/ci/wasm-page.ts`): the same; off, posting the shared memory is a `DataCloneError`.
  Servo 0.6 has no `crossOriginIsolated` and no `SharedArrayBuffer` either way, a shared
  `WebAssembly.Memory` is a `LinkError`: a Servo build with `wasm.threads` is warned about
  and goes on. Every template (19): `biome check` and `build` pass, the dev server sends
  both headers on and none off.
- Engine-neutral names for what `main.zig` and plugins use (API freeze for 0.2.0's native
  apps): `core.commands` (`checkedWith`, `pluginCommands`, `permissionList`, `HandlerError`,
  `PluginCommand`, `Later`, `takeLater`; `zig/src/commands.zig`) and `core.events`
  (`Declared`, `Target`). `events.Target` is where events go, whatever carries them;
  `Bridge.eventTarget()` makes one, the template's `main.zig` hands it to `Declared.emit` and
  to plugins' `tick`. The `webview…` names stay, and `emit`/`tick` still take the bridge
  itself, so older `main.zig` files and published plugins build unchanged. Measured: Zig
  0.16 and 0.17, webview and native tests; a project with `plugin-fs` updated, its page
  received `fs.changed` (`created`, `modified`) through the target on WPE; Windows and
  native builds of it compile.

### Changed

- A Linux `.tar.gz` is an AppDir (`commands/appdir.rs`): the bundle under `usr/`, and at
  the top `AppRun` (a POSIX sh script), `<identifier>.desktop`, `<identifier>.svg`,
  `.DirIcon` (the 256 px PNG), `install.sh` and `uninstall.sh`. `install.sh` copies `usr/`
  into `~/.local` (or `/usr/local` with `--system`), makes the entry's `Exec` absolute and
  lists the files it wrote and the directories that did not exist before; `uninstall.sh`
  removes those, deepest directory first, a desktop cache left alone in one of them with
  it. Measured in a fresh home (nothing left) and one shared with another app (its files
  and the shared `mimeinfo.cache` kept); `desktop-file-validate` passes the installed
  entry. `--system` not measured (needs sudo). `--verify` starts the `.tar.gz` through
  `AppRun`; on Windows the archive marks the three scripts executable by name.
- API freeze for 0.1.9 (`docs/plans/uyumluluk-0.2.0.md`): the transport's shapes left the
  SDK's entry points. `encodeRequest`, `decodeReply`, `wireLayout`, `commandId`, the layout
  types and `decodeEvents` are `src/wire.ts`; `decodeState`, `encodeMenu`, `decodeDownload`
  and `decodePermissionRequest` are `src/payloads.ts`; neither is in `exports`
  (`ERR_PACKAGE_PATH_NOT_EXPORTED`, measured). No plugin or template used them.

### Fixed

- `lepton package --verify` on Windows closed the app with `taskkill /PID`, which
  answered SUCCESS for the native template app while it ran on (CI 40379633600,
  40389406515). `close_windows` (`verify_windows.rs`) posts `WM_CLOSE` to every visible,
  unowned top-level window of the process through PowerShell's `Add-Type`, and the close
  is timed from there; the timeout now carries the stderr tail, on Linux too. Measured
  on the runner: `WM_CLOSE` to `LeptonWindow` ends the app with 0 in ReleaseSmall and
  Debug. The process also has a visible, untitled `MicrosoftWindowsTooltip` window from
  about 1.6 s to 5.6 s, on the app's thread, created with no instance and its class under
  the program's module handle; of the 46 loaded modules only `USER32.dll` carries the
  name, and Lepton's program does not (`windows.yml` "Native windows", "Tooltip class
  name").
- `lepton update` in a project made by the Linux 0.1.9-beta.2 CLI reported the framework's
  own changes as the developer's (a conflict "since 0.1.6"): beta.2 went out from Windows
  with the template before `main.zig` was split and from Linux with the one after it
  (d1a67df), and `assets/history` had only the first. The second is
  `history/0.1.9-beta.2-linux/` (measured: the published binaries embed exactly these
  files); such a project's `main.zig` and `build.zig` are now replaced as untouched.

### Measured

- Memory on Windows (`windows.yml` "Memory", Windows Server 2025, no GPU: Direct3D 11
  runs on WARP there): the vanilla-ts template packaged and run by `--verify`, the tree's
  private working set after 3 s. Web view: 69.4 MB, 7 processes (70.6 and 72.9 MB in
  earlier runs); native: 6.9 MB on Direct3D 11, 5.9 MB with `LEPTON_GPU=cpu`, 1 process.
- Frames inside the app's page (WPE WebKit 2.54, a probe page with three child frames):
  `__lepton` is injected into the top frame only (`inject_top_frame`), but a same-origin
  `srcdoc` or `about:blank` frame reads the run's key from `parent.__lepton`, builds a
  request frame from its `layout` and calls the core: `app.args` answered `ok`, the
  unlisted `window.title` `denied`, `events?after=latest` 200. A frame sandboxed with
  `allow-scripts` alone got `SecurityError` on `parent.__lepton` and no key. This is the
  web's same-origin rule, not something the core can tell apart; the site's Web features
  page says so and points untrusted content to `sandbox` without `allow-same-origin`.
  WebView2 and Servo not measured yet.

## 0.1.9-beta.2 *2026-10-25*

Published in two parts under `beta`. On 2026-10-24 from Windows at `9fbb8bc`:
`@lepton-desk/cli-win32-x64`, `api`, `plugin-clipboard`, `plugin-dialog`. On 2026-10-25
from Linux at `d1a67df`: `@lepton-desk/cli`, `cli-linux-x64`, `plugin-fs`, `plugin-os`,
`create-lepton-app`, `servo-linux-x64`.

### Added

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

- `identifier`, `productName`, `channel.name`, `window.title` reach every build as
  `-Didentifier`, `-Dproduct`, `-Dchannel`, `-Dtitle`; `main.zig` reads `who.*`. An
  identifier changed after `lepton new` used to reach the installer but not the program.
- The core answers the application's own page only: a random key per run under
  `/__lepton/<key>/`, written only into the transport of that page.
- Other sites open in the system browser (http, https, mailto only).
- File grants live in the app's state folder; a save dialog grants the file, not its folder.
- Channel names are per user (`.u<uid>`).
- `lepton build --macos` is refused with the reason.
- The CLI picks Zig itself (`LEPTON_ZIG`, else `zig`, `zig-0.17`, `zig-0.16`), and every
  Linux binary links through LLVM and LLD (`throughLld`).

### Fixed

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

### In the Linux packages only

Between the two commits, so in the 2026-10-25 packages; the Windows CLI gets them with
beta.3.

#### Added

- Servo: cursors (`servo/cursor_x11.zig`; the bridge's `cursor` callback,
  `LeptonServoCallbacks` now 64 bytes) and the resize shape over a frameless window's
  edge band.

#### Changed

- `sdkScope` is read: `lepton update` moves the dependencies under it and asks the
  registry for `<sdkScope>/cli`, and the linked-package watcher looks under it. It was
  written into every project and read by nothing. The CLI and the schema check it is an npm
  scope.
- The template's `main.zig` is split: the `--target native` program is
  `src-lepton/native.zig`, a framework file that reads `who` from `main.zig` through
  `@import("root")`. `lepton update` manages it (`Part::Native`; added when missing), and
  `tools/release-version.mjs` keeps it in the template history. `main.zig` was 964 lines.
- The app's own folders are narrowed to 0700 when they exist wider
  (`paths.makeOwnPrivate`: last component only, not through a link, only the user's own).

#### Fixed

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
- With both, a package made on Linux and one made on Windows are the same bytes: the
  `zip` and the `msi` (`windows` workflow, `compare.txt`: identical). The last difference
  was the program's mode in the zip (0644 from Linux); it is installed executable again.
- A web view program refuses Windows older than 10 when it starts, with a message box
  (`webview2/view.zig`): WebView2 stopped at 109 there and gets no security fixes. The PE
  header could not say it: Zig writes 6.0 whatever the target and has no option, and a
  header set to 10.0 afterwards left the program running with no window and no WebView2
  process on the runner, while the same bytes with 6.0 opened (measured A/B). The header
  stays 6.0, and `windows.yml` checks that. A missing WebView2 runtime is a message box
  too, not a silent exit.

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
