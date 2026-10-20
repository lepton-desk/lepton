/* Generated from the @cImport that was in src/tools/webview2_check.zig: translated by the build
   (`addCModules` in build_support.zig), since Zig 0.17 has no @cImport. Each
   include is guarded, so a missing library leaves its names out instead of
   failing the build; the code that uses them is compiled only when it is there. */
/* Windows only: WebView2.h and the shell headers read Windows' own (rpc.h, ...). */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN 1
#if __has_include(<windows.h>)
#include <windows.h>
#endif
#if __has_include(<objbase.h>)
#include <objbase.h>
#endif
#if __has_include(<shlwapi.h>)
#include <shlwapi.h>
#endif
#if __has_include(<psapi.h>)
#include <psapi.h>
#endif
#if __has_include(<WebView2.h>)
#include <WebView2.h>
#endif
#endif
