# What the runtime is built from

`LICENSE` is the runtime's own (AppImage/type2-runtime, MIT), and lists the libraries
linked into it statically with their licences. The sources of this build, release
`20251108`:

- the runtime: <https://github.com/AppImage/type2-runtime/tree/20251108>
  (`src/runtime/runtime.c`, built by `scripts/chroot/build.sh` in Alpine Linux);
- libfuse 3.15.0, LGPL-2.1:
  <https://github.com/libfuse/libfuse/releases/download/fuse-3.15.0/fuse-3.15.0.tar.xz>,
  with `patches/libfuse/mount.c.diff` from the runtime's tree applied;
- squashfuse 0.5.2, BSD-2-Clause: <https://github.com/vasi/squashfuse/archive/0.5.2.tar.gz>;
- musl libc, zstd, zlib and mimalloc from Alpine Linux's packages at build time
  (`scripts/common/install-dependencies.sh`, `scripts/chroot/build.sh`). mimalloc (MIT) is
  linked as well (`src/runtime/Makefile`: `-lmimalloc`), though `LICENSE` does not list it.

The binary here is not rebuilt or changed; to relink it against a modified libfuse, build
the runtime from the tree above.
