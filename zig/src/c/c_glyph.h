/* Generated from the @cImport that was in src/render/glyph_text.zig: translated by the build
   (`addCModules` in build_support.zig), since Zig 0.17 has no @cImport. Each
   include is guarded, so a missing library leaves its names out instead of
   failing the build; the code that uses them is compiled only when it is there. */
/* Not on Windows: a Windows build's translation must not find the host's own headers. */
#ifndef _WIN32
#if __has_include(<freetype/freetype.h>)
#include <freetype/freetype.h>
#endif
#if __has_include(<hb.h>)
#include <hb.h>
#endif
#if __has_include(<hb-ft.h>)
#include <hb-ft.h>
#endif
#if __has_include(<fontconfig/fontconfig.h>)
#include <fontconfig/fontconfig.h>
#endif
#endif
