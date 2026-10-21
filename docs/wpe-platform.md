# Lepton'ın kendi WPE platformu

Karar (2026-10-21): WPE WebKit sayfasını WPE'nin kendi Wayland platformu yerine Lepton'ın
platformuna çizecek. WebKit yaması değil: `WPEDisplay` alt sınıfı WebKit'in
`wpe-platform-display` uzantı noktasına kaydolur, `WPE_PLATFORM=lepton` ile seçilir
(`zig/src/render/webview/platform/lepton_display.zig`).

## Neden

WPE 2.54'ün Wayland platformu (`WPEToplevelWayland.cpp`, `webkitglib/2.54`):

- süsleri hep sunucuya bırakır (`ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE`), istemci
  tarafı süs çizemez; xdg-decoration sunmayan bir bileşimcide pencerenin hiç çerçevesi
  olmaz (kaynaktaki yorum; GNOME'da ölçülmedi);
- `xdg_toplevel`'ı dışarı vermez, yani `xdg_toplevel_move`/`resize`/`show_window_menu`
  ve `xdg_popup` Lepton'dan yapılamaz;
- başlık çubuğunun rengini sayfaya uyduracak bir yol yoktur (Wayland'de bunun protokolü
  yok; Lepton kendi çizerse olur). Ölçüldü: COSMIC X11'de `_GTK_THEME_VARIANT`'ı da yok
  sayıyor (açık/koyu görüntüler piksel piksel aynı).

Kendi platformla: `window.decorations: false`, `window.start_drag`, `window.menu`,
sayfayı izleyen başlık çubuğu, `ext_background_effect_manager_v1` bulanıklığı ve
ileride Lepton'ın kendi camı (sayfanın altında/üstünde Lepton'ın çizdiği katmanlar).

## Bugün (ölçüldü, `zig build platform-check`)

`WPELeptonDisplay` varsayılan ekran seçiliyor. Görünüm, tampon, girdi, pencere yok.

## Adımlar

Her adım ölçülerek biter; WPE'nin kendi platformu her adımda yedek kalır (Lepton'ın
platformu bağlanamazsa `connect` başarısız olur, WebKit sıradakine geçer).

1. **Sayfa görünsün (shm).** `WPEView` alt sınıfı, `render_buffer` tamponu Lepton'ın
   Wayland penceresine (`window/linux/wayland_window.zig`) `wl_shm` ile koyar; çerçeve
   geri çağrısında `wpe_view_buffer_rendered`/`released`. Bitti: şablon sayfa çizildi,
   canlı veri akıyor.
2. **GPU yolu (dmabuf).** EGL ekranı `wl_display` üzerinde, `zwp_linux_dmabuf_v1` ile
   kopyasız sunum; biçim/değiştirici geri bildirimi. Bitti: aynı sayfada CPU ve kare
   süresi WPE'nin kendi platformuyla karşılaştırıldı.
3. **Girdi.** İşaretçi (seri numaralarıyla), tekerlek, klavye (`wl_keyboard` keymap →
   `WPEKeymapXKB`, tekrar), dokunma. Bitti: tıklama, yazma (Türkçe dahil), kaydırma.
4. **Pencere.** Başlık, boyut, büyütme/küçültme/tam ekran, `window.state`/`resized`
   olayları, ölçek (`wp_fractional_scale_v1`, `wp_viewporter`), ekranlar (`wl_output`).
   Bitti: `window.*` komutları WPE'nin kendi platformundaki değerlerle aynı.
5. **Süs ve taşıma.** xdg-decoration pazarlığı; `decorations: false` → süs yok;
   bileşimci istemci tarafı isterse ya da sayfa `theme-color` verirse Lepton'ın başlık
   çubuğu (`window/linux/chrome.zig`, alt yüzey), sayfanın rengini izler;
   `xdg_toplevel_move`/`resize` basışın seri numarasıyla. Bitti: COSMIC'te ekran
   görüntüleri; GNOME'da CI ya da sanal makinede.
6. **Menü.** `window.menu` → `xdg_popup` (tutuşla), Cairo ile, Servo'nun X11 menüsüyle
   (`servo/menu_x11.zig`) aynı çizim. Bitti: fare, klavye, odak kaybında kapanma.
7. **Geri kalanlar.** Pano (`WPEClipboard`, `wl_data_device`), IME (`text-input-v3` →
   `WPEInputMethodContext`), imleç şekilleri (`wp_cursor_shape_v1`), sürükle-bırak,
   erişilebilirlik. Bitti: her biri için WPE'nin kendi platformundaki davranışla ölçüm.
8. **Malzeme.** `window.material`: saydam sayfa arka planı + `ext_background_effect`
   bulanıklık bölgesi; sunulmazsa opak ve sayfaya olay. Bitti: COSMIC'te görüntü.
9. **Varsayılan yapmak.** Lepton uygulamaları `WPE_PLATFORM=lepton` ile açılır; adım
   1–7 ölçülmeden varsayılan olmaz.
