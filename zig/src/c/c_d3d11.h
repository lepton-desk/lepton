/* Direct3D 11 and DXGI for the native path's GPU half on Windows. Its own translation: the
   window layer (`c_windows.h`) and the webview builds need none of it. Translated by the
   build (`addCModules` in build_support.zig). */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN 1
#if __has_include(<windows.h>)
#include <windows.h>
#endif
#if __has_include(<d3d11.h>)
#include <d3d11.h>
#endif
#if __has_include(<dxgi1_2.h>)
#include <dxgi1_2.h>
#endif
#endif
