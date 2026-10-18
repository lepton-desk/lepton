# WebView2 headers

`WebView2.h` and `LICENSE.txt` are copied unchanged from the `Microsoft.Web.WebView2`
NuGet package, version **1.0.4258.31** (`build/native/include/WebView2.h`, package
SHA-256 `56F7F4B8BF9AEE4B8EFEFBBDD4F67D5F74EBD1B100ED0806DA71BF76AF481AA9`), under
Microsoft's BSD-style license in `LICENSE.txt`.

Only the header is used: Lepton does not ship `WebView2Loader.dll` or link
`WebView2LoaderStatic.lib`. The runtime is found the way the loader finds it (the
`EBWebView` value under `HKLM`/`HKCU` `SOFTWARE\Microsoft\EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`)
and its `EBWebView\<arch>\EmbeddedBrowserWebView.dll` is loaded directly.

`EventToken.h` is Lepton's: mingw-w64 lacks the Windows SDK file of that name.
