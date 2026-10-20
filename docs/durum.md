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
- **Servo (deneysel):** `npm install -D @lepton-desk/servo-linux-x64` + `lepton build --linux --servo`; bu makinede ölçüldü: pencere açıldı, sayfa canlı veriyi çizdi, Ctrl+C temiz.

## Açık kalanlar

- Windows ölçümleri (yukarıda).
- Servo: klavye girişi yok; Wayland'de XWayland üzerinden; `lepton run`/`dev`'de `--servo` bayrağı yok (derlenen ikili doğrudan çalıştırılıyor).
- `fs.watch`: alt klasörler izlenmiyor; Windows yok.
- AUR paketleri 0.1.8'i paketliyor ve `zig0.16`'ya bağlı; bir sonraki kararlı sürümde Arch'ın `zig`'ine geçilecek.
- Beta.3 adayları: WASM eklentileri (önce tasarım belgesi), arm64+x64 paketleme, Windows imzalama, çalışma zamanı yetki sorusunun genel mekanizması (`fs` ile başlayarak).
