# @lepton-desk/appimage-runtime-linux-x64

The AppImage type-2 runtime for linux-x64, byte for byte the `runtime-x86_64` of
[AppImage/type2-runtime](https://github.com/AppImage/type2-runtime) release
[`20251108`](https://github.com/AppImage/type2-runtime/releases/tag/20251108)
(944 632 bytes, SHA-256 `2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d`).

`lepton package` writes an AppImage as this runtime followed by the app's file system. It
finds the runtime in the project's dependencies and checks its SHA-256 before using it:

```sh
npm install -D @lepton-desk/appimage-runtime-linux-x64
```

The runtime is statically linked and needs no libfuse on the machine that runs the
AppImage. Its licence and the licences of the code it links are in `LICENSE` and
`THIRD-PARTY.md`.
