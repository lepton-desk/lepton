/* Text on the native path on Windows (`src/render/text_windows.zig`): DirectWrite lays out
   and shapes, Direct2D rasterises into a GDI DIB. Its own translation: the window layer's
   (`c_windows.h`) does not need these headers, and every webview build would translate
   them for nothing. Translated by the build (`addCModules` in build_support.zig). */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN 1
#if __has_include(<windows.h>)
#include <windows.h>
#endif
#if __has_include(<d2d1.h>)
#include <d2d1.h>
#endif
#if __has_include(<dwrite.h>)
#include <dwrite.h>
#endif
#endif
