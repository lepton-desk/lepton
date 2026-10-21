# Durum: 0.1.9-beta.2 (2026-10-21)

Bu dosya, sürüm hazırlığının nerede durduğunu herhangi bir makineden (Windows dahil) `git pull` ile okunabilir kılmak için var. Yayın adımları `docs/yayin.md`'de; burası neyin yapıldığını, neyin ölçüldüğünü ve neyin açık kaldığını söyler. Sürüm çıkınca güncellenir.

## Yayın durumu

- Bütün paketler `0.1.9-beta.2`'de, commit `f4e8fec` (trunk). Hiçbiri yayımlanmadı.
- `tools/npm-preflight.sh` Linux'ta tek bir yerde duruyor: `@lepton-desk/cli-win32-x64` yerleştirilmedi. Bu bekleniyor; sıra Windows'tan başlar.
- `@lepton-desk/servo-linux-x64`'ün kitaplığı CI'dan geldi (`servo-bridge`, çalıştırma 39491335347, SHA-256 `f67bde25…a4f`, CI raporuyla aynı) ve `tools/stage-servo.mjs` ile yerleştirildi. Kitaplık git'te değil: yayımlayan makinede yeniden yerleştirilmeli.

## Windows'ta yapılacaklar

1. `git pull`, sonra `docs/yayin.md`'deki "4a. Windows" adımları: CLI'yi derleyip yerleştirin (`cargo build --release --bin lepton`, `node packages/cli/scripts/stage.mjs`) ve oradan çıkan paketleri yayımlayın (`cli-win32-x64`, `api`, `plugin-clipboard`, `plugin-dialog`; `--tag beta`). Sonra Linux'ta ön kontrol ve kalan paketler.
2. Windows'ta henüz **ölçülmemiş**, yalnız derlenmiş olanlar (Linux'tan çapraz derleme geçiyor):
   - `clipboard` eklentisi (okuma artık son 5 sn içindeki gerçek girdiye bağlı: `GetLastInputInfo` + öndeki pencere bu süreçin mi).
   - Tek kopya: `\\.\pipe\lepton-<identifier>` (`PIPE_NOWAIT`, `PIPE_REJECT_REMOTE_CLIENTS`). İkinci başlatma argümanlarını birinciye vermeli.
   - Derin bağlantılar: MSI `HKCU\Software\Classes\<şema>` yazıyor (`URL Protocol` değeri `"1"`; Windows'un yalnız değerin varlığına baktığı varsayımı ölçülmedi).
   - Varsayılan simge: MSI `bundle.icon` yoksa Lepton'ın `.ico`'sunu kullanıyor (PNG çerçeveli ICO, 16–256 px).
   - `fs.watch` Windows'ta `failed` döner (henüz `ReadDirectoryChangesW` yok).

Linux'ta ölçülen her şey aşağıda; Windows'ta ölçüm yapınca bu dosyaya yazın.

## 0.1.9-beta.2'de ne var (Linux'ta ölçüldü)

- **Güvenlik (yüksek/orta/düşük):** çekirdek yolları çalıştırma başına rastgele anahtarın arkasında (`/__lepton/<anahtar>/…`); transport yalnız uygulamanın kendi sayfasına; başka siteler pencereye girmiyor (WPE, WebView2, Servo); dışarıda yalnız http/https/mailto açılıyor; izinler state dizininde; kaydetme penceresi yalnız dosyaya izin veriyor, ev ve üstüne izin yok; yapılandırma değerleri denetleniyor ve kaçışlanıyor; `plugin-fs` ofset taşması ve `.lepton-save` izinleri; Servo gövde sınırı ve zaman aşımı; replay ev dizini, semver ön sürüm, bağlantı üzerinden yazmama; `bundle.icon` proje içinde; `/dev/shm` adları kullanıcıya özel; ertelenmiş özel cevaplar maskeli.
- **Ctrl+C:** `lepton dev`'de kanal dosyası kalmıyor (önce 4 dosya kalıyordu), `✔ app`.
- **Pano okuma kullanıcı girdisi istiyor:** yüklemede `NotAllowedError`, tıklamadan sonra okundu. `"plugins": { "clipboard": { "read": "always" } }`.
- **Tek kopya + derin bağlantı:** `xdg-open myapp://…` çalışan sayfaya ulaştı, ikinci pencere açılmadı; kapalı uygulamayı açan bağlantı `launchArgs()`'ta geldi. `deepLinks`, `@lepton-desk/api/app`.
- **`fs.watch`:** sayfanın ve başka programın yazdıkları geldi (inotify).
- **Varsayılan simge:** `src-lepton/icon.svg`, Linux paketinde `share/icons/hicolor/scalable/apps/<id>.svg`.
- **Kimlik:** `com.<sahip>.<uygulama>`, `--owner`.
- **Zig 0.16 ve 0.17:** ikisiyle de çekirdek testleri, araçlar, bütün eklentili webview uygulaması (derlendi, çalıştı, Windows'a çapraz derlendi), yerel uygulama. CI `zig` iş akışı ikisini de çalıştırıyor (geçti).
- **Servo (deneysel, yalnız Linux):** `npm install -D @lepton-desk/servo-linux-x64`, sonra `lepton build --linux --servo`, `lepton run --servo` ya da `lepton dev --servo`. Bu makinede ölçüldü: sayfa canlı veriyi çizdi; `dev`'de sayfa dev sunucusundan geldi, düzenleme sayfayı yeniledi; Ctrl+C hemen bitiriyor, dosya kalmıyor, SIGTERM'de çıkış kodu 0.

## Açık kalanlar

Servo yalnız Linux içindir ve öyle kalacak: Windows'ta motor WebView2'dir (Chromium tabanlı, sistemle gelir, Microsoft günceller). `--servo` başka sistemde reddedilir.


- Windows ölçümleri (yukarıda).
- Servo: Wayland'de XWayland üzerinden. Servo kapanışta sürecin sonuna bırakılıyor (`_exit`): kendi kapanışı worker'ları süresiz bekliyor.
- `fs.watch`: Windows yok.
- AUR paketleri 0.1.8'i paketliyor ve `zig0.16`'ya bağlı; bir sonraki kararlı sürümde Arch'ın `zig`'ine geçilecek.
- Beta.3 adayları: WASM eklentileri (önce tasarım belgesi), arm64+x64 paketleme, Windows imzalama, çalışma zamanı yetki sorusunun genel mekanizması (`fs` ile başlayarak).

## Sabah buradan devam (2026-10-21 gecesi bırakıldı)

- **Önce:** `servo-bridge` iş akışını çalıştırın. Köprüye `lepton_servo_set_data_directory` eklendi (Rust, burada derlenmedi). Yeni `liblepton_servo` artifact'ını `tools/stage-servo.mjs` ile yerleştirin: paketteki eski kitaplıkta bu fonksiyon yok, `--servo` derlemesi onunla bağlanmaz.
- **Ölçülecek (yazıldı, Servo derlemesinde denenmedi):** sayfanın `window.minimize/maximize/unmaximize/state` komutları ve `window.state`/`window.resized` olayları (X11, EWMH); `$APPDATA/servo` veri klasörü ve `localStorage`/çerezlerin `_exit` ile kapanıştan sonra kalıp kalmadığı.
- **Ölçüldü (bu gece):** Servo'da klavye (`Ab ş`, Backspace, Enter) ve tekerlek (adım başına 48 px); pencere WPE pencereleriyle aynı yer ve boyutta açılıyor (eşlenmeden önce boyutlanıp ortalanıyor); `fs.watch({ recursive: true })` (testler iki Zig'de).
- **Servo'nun kalan eksikleri:** Wayland'de kendi yüzeyi (köprü Wayland yüzeyini kabul ediyor, çekirdek tarafı yok); pano X11'de `failed`, dosya diyalogları Servo altında ölçülmedi; klavyede dead key/compose/IME ve `repeat` yok; motor izinleri (bildirim, kamera) sorulmuyor; paket yalnız Linux x86_64 için (arm64 yok).

## 2026-10-21 sabahı

- `servo-bridge` çalıştırma 39562336822: kitaplık derlendi (`lepton_servo_set_data_directory` dahil 19 fonksiyon), SHA-256 `dfe24a8e…6d72`, `tools/stage-servo.mjs` ile yerleştirildi. Aynı işin şablon uygulama adımı iki nedenle düştü: runner'da `libxkbcommon-dev` yoktu (çekirdek artık xkbcommon'a bağlanıyor) ve `lepton new --install` yayımlanmamış `@lepton-desk/api@0.1.9-beta.2`'yi npm'de aradı. İkisi iş akışında düzeltildi (yerel), yeniden çalıştırılmadı.
- **Servo'da pencere komutları (ölçüldü):** `maximize`, `unmaximize`, `minimize`, `state` çalışıyor; `window.state` olayları geliyor. `window.resized` hiç gelmiyordu: Servo'nun kullandığı `pumpOne` X olaylarını `applyEvent`'e veriyordu, o da `ConfigureNotify`'ı işlemiyordu (Servo'ya yeni boyut da gitmiyordu). Ayrıca `pumpOne`/`pumpEvents` olayları `free` etmiyordu. Düzeltildi; şimdi büyütmede 1366×652, geri almada 910×422 geliyor, WPE ile aynı değerler.
- **Kapatma (ölçüldü):** çekirdeğin X11 penceresi `WM_PROTOCOLS`'a `WM_DELETE_WINDOW` yazmıyordu; pencere yöneticisinin kapatma isteği uygulamaya ulaşamıyordu. Düzeltildi; doğrudan gönderilen `WM_DELETE_WINDOW` ile uygulama temiz kapandı (`✔ app`, `/dev/shm`'de dosya yok). Ayrıca artık yalnız bu ileti kapatma sayılıyor (önce her istemci iletisi sayılıyordu). COSMIC'in XWayland'i dışarıdan gönderilen `_NET_CLOSE_WINDOW`'u uygulamıyor; başlık çubuğundaki gerçek düğme ölçülmedi.
- **Servo'da kalıcı depolama yok (ölçüldü):** Servo `lepton://localhost/`'u opak köken sayıyor (`url` crate'i yalnız http/https/ws/wss/ftp'ye demet köken veriyor; Servo 0.6'nın `ProtocolHandler`'ında bunu değiştiren seçenek yok). `localStorage` `SecurityError: Cannot access localStorage from opaque origin` atıyor. WPE'de aynı sayfada `localStorage` çalışıyor ve kapanıştan sonra kalıyor (`runs:1`, sonra `runs:2`). `document.cookie` iki motorda da boş kalıyor. Veri klasörünün kalıcılığı bu yüzden Servo'da ölçülemedi. Çözüm yolu kararı bekliyor.
- **Servo'da kalıcı depolama (düzeltildi, ölçüldü):** `servo/patches/servo-url` (servo-url 0.6.0'ın kopyası, değişiklikler `Lepton:` ile işaretli) `register_tuple_origin_scheme`'i ekliyor; köprü uygulamanın şemasını Servo'dan önce kaydediyor, `lepton://localhost/` sayfası `(lepton, localhost)` kökenini alıyor. Servo yükseltilirken bu yama taşınmalı. `servo-bridge` çalıştırma 39568382520 köprüyü yamayla derledi (köprü testleri ve pencere denetimi geçti; SHA-256 `3db5a306…3286`, yerleştirildi). Bu makinede: `localStorage` çalışıyor ve kapanıştan sonra kalıyor (`runs:1`, `runs:2`, `runs:3`), veri `$APPDATA/servo/webstorage/` altında SQLite'ta, köken anahtarı `lepton://localhost`; Ctrl+C sonrası `✔ app`, `/dev/shm`'de dosya yok. `document.cookie` (WPE'de de) boş kalıyor. Şablon adımı bu çalıştırmada `packages/api`'yi derleyecek pnpm olmadığı için düştü; iş akışına eklendi ve çalıştırma 39571070444'te bütün iş geçti (şablon uygulama derlendi, açıldı, sayfa `/__lepton/<anahtar>/region` okudu).
- **Ctrl+C'de eksik `✔ app` satırı (ölçüldü, düzeltildi):** aralıklı değil, bir yarıştı. Sinyal işleyicisi çocukları kapatıp `exit(130)` diyor, ana iş parçacığı aynı anda uygulamanın satırını yazıyordu; dört turdan birinde işleyici önce davrandı (çıkış 130, satır yok), diğerlerinde ana iş parçacığı (çıkış 0). Artık uygulama `supervise::foreground` ile işaretli, işleyici çocukları kapattıktan sonra (en çok `GRACE`) o satırı bekliyor, çıkışı her zaman işleyici veriyor: `run`'da altı turda altı `✔ app`, çıkış 130; `dev`'de iki turda iki `✔ app` ve oturum özeti, Vite kapanıyor, `/dev/shm` boş.
- **`document.cookie` (ölçüldü, çözüldü):** WebKit (`Document::isCookieAverse`) ve Servo (`is_cookie_averse`) HTML standardı gereği http(s)/ftp/file dışındaki şemadaki belgeye çerez vermiyor; köken yaması bunu değiştirmez, WPE dağıtımın paketi olduğu için yamalanamaz. Transport artık yalnız uygulamanın kendi sayfasında ve yalnız ağ şeması dışındaki adreste `document.cookie`'yi tanımlıyor (`zig/src/render/webview/cookie_shim.js`, `localStorage`'da `__lepton.cookies`; RFC 6265'in betik kuralları, `cookie_shim.test.mjs` `zig` iş akışında çalışıyor). Ölçüldü: WPE ve Servo'da bir çalıştırmada yazılan çerez sonrakinde okundu. Dev sunucusundaki sayfada şim kurulmuyor; oradaki gerçek çerezler bu turda ölçülmedi. Windows'ta ölçülmedi (sayfa `http://lepton.localhost`, şim kurulmaz).
