/* Generated from the @cImport that was in src/ipc/shm_posix.zig: translated by the build
   (`addCModules` in build_support.zig), since Zig 0.17 has no @cImport. Each
   include is guarded, so a missing library leaves its names out instead of
   failing the build; the code that uses them is compiled only when it is there. */
/* Not on Windows: a Windows build's translation must not find the host's own headers. */
#ifndef _WIN32
#define _GNU_SOURCE 1
#if __has_include(<errno.h>)
#include <errno.h>
#endif
#if __has_include(<fcntl.h>)
#include <fcntl.h>
#endif
#if __has_include(<sys/mman.h>)
#include <sys/mman.h>
#endif
#if __has_include(<sys/stat.h>)
#include <sys/stat.h>
#endif
#if __has_include(<sys/types.h>)
#include <sys/types.h>
#endif
#if __has_include(<unistd.h>)
#include <unistd.h>
#endif
#endif
