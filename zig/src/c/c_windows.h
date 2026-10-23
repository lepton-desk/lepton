/* Windows, translated once for the window layer (src/window/windows/) and the WebView2
   path (src/render/webview/webview2/): one translation, so both see the same HWND and
   RECT types — two translations of <windows.h> are two sets of distinct Zig types.
   Translated by the build (`addCModules` in build_support.zig), since Zig 0.17 has no
   @cImport. Each include is guarded, so a missing header leaves its names out instead
   of failing the build. WebView2.h is types only (the runtime is loaded at run time,
   `webview2/runtime.zig`), so a native build that reads it links nothing more. */
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
#if __has_include(<shellapi.h>)
#include <shellapi.h>
#endif
#if __has_include(<psapi.h>)
#include <psapi.h>
#endif
#if __has_include(<dwmapi.h>)
#include <dwmapi.h>
#endif
#if __has_include(<WebView2.h>)
#include <WebView2.h>
#endif
/* The native path's GPU half (`render/gpu/d3d11.zig`): here rather than in a header of its
   own, so the swap chain is made on the window's own HWND type — a handle crossed between
   two translations needs an alignment cast, and a handle's value need not be aligned. */
#if __has_include(<d3d11.h>)
#include <d3d11.h>
#endif
#if __has_include(<dxgi1_3.h>)
#include <dxgi1_3.h>
#endif
/* Tearing for unlimited frames (`IDXGIFactory5::CheckFeatureSupport`, Windows 10 1607+). */
#if __has_include(<dxgi1_5.h>)
#include <dxgi1_5.h>
#endif
#endif
