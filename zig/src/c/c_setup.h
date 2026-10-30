/* setup.exe (`src/setup/`): the window, the shell link and its property store, known
   folders. Translated by the build (`addCModules` in build_support.zig). */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN 1
#if __has_include(<windows.h>)
#include <windows.h>
#endif
#if __has_include(<commctrl.h>)
#include <commctrl.h>
#endif
#if __has_include(<shlobj.h>)
#include <shlobj.h>
#endif
#if __has_include(<shobjidl.h>)
#include <shobjidl.h>
#endif
#if __has_include(<propsys.h>)
#include <propsys.h>
#endif
#if __has_include(<shellapi.h>)
#include <shellapi.h>
#endif
#endif
