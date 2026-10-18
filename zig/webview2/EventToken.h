/* WebView2.h includes the Windows SDK's EventToken.h, which mingw-w64 (Zig's Windows
 * headers) does not ship. It defines this one struct; the layout is the SDK's: a token
 * returned by every add_* event registration and handed back to remove_*. */
#pragma once
typedef struct EventRegistrationToken {
    __int64 value;
} EventRegistrationToken;
