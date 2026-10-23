# Durum: 0.1.9-beta.2 (2026-10-21)

Bu dosya, sürüm hazırlığının nerede durduğunu herhangi bir makineden (Windows dahil) `git pull` ile okunabilir kılmak için var. Yayın adımları `docs/yayin.md`'de; burası neyin yapıldığını, neyin ölçüldüğünü ve neyin açık kaldığını söyler. Sürüm çıkınca güncellenir.

## Yayın durumu

- Bütün paketler `0.1.9-beta.2`'de, commit `f4e8fec` (trunk). Hiçbiri yayımlanmadı.
- `tools/npm-preflight.sh` Linux'ta tek bir yerde duruyor: `@lepton-desk/cli-win32-x64` yerleştirilmedi. Bu bekleniyor; sıra Windows'tan başlar.
- Windows tarafı hazır (2026-10-21): `cli-win32-x64` yerleştirildi, `api`, `plugin-clipboard`, `plugin-dialog`'un `prepublishOnly`'si geçti. Yayımlayan kişi `docs/yayin.md` 4a'daki dört komutu çalıştırır. `beta.1` yayında (`beta` etiketi).
- `@lepton-desk/servo-linux-x64`'ün kitaplığı CI'dan geldi (`servo-bridge`, çalıştırma 39491335347, SHA-256 `f67bde25…a4f`, CI raporuyla aynı) ve `tools/stage-servo.mjs` ile yerleştirildi. Kitaplık git'te değil: yayımlayan makinede yeniden yerleştirilmeli.

## Windows'ta yapılacaklar

1. `git pull`, sonra `docs/yayin.md`'deki "4a. Windows" adımları: CLI'yi derleyip yerleştirin (`cargo build --release --bin lepton`, `node packages/cli/scripts/stage.mjs`) ve oradan çıkan paketleri yayımlayın (`cli-win32-x64`, `api`, `plugin-clipboard`, `plugin-dialog`; `--tag beta`). Sonra Linux'ta ön kontrol ve kalan paketler.
2. ~~Windows'ta ölçülmemiş olanlar~~ — 2026-10-21'de Windows 10 22H2'de ölçüldü (aşağıda).

Linux'ta ölçülen her şey aşağıda; Windows'ta ölçüm yapınca bu dosyaya yazın.

## Windows'ta ölçüldü (2026-10-21, Windows 10 22H2)

Önce: `cargo test --workspace` 347 geçti, `zig build test` (Windows kökü) 51/54 (3 atlandı), `lepton --version` → `0.1.9-beta.2`. `cli-win32-x64` yerleştirildi (6 685 184 bayt); `api`, `plugin-clipboard`, `plugin-dialog` `npm run prepublishOnly` 0; dört tarball `--dry-run` temiz, `beta.2` npm'de boş. Deneme: `lepton new` vanilla-ts, `clipboard,fs`, `deepLinks: ["leptone2e"]`, `bundle.targets: ["msi"]`, paketler `link:`.

- **Varsayılan simge:** MSI 217 088 bayt, `msiexec /qn` 0. Kurulu ürünün `product.ico`'su CLI'nin `assets/icon.ico`'suyla bayt bayt aynı: 7 PNG çerçeve (16, 24, 32, 48, 64, 128, 256). 16/32/48 px `System.Drawing.Icon` ile çizildi (243/1003/2263 opak piksel); 256'yı `System.Drawing` açamıyor (kendi PNG sınırı, kabuğun değil — ölçülmedi). Başlat menüsü kısayolu `product.ico,0`'ı gösteriyor.
- **Derin bağlantı:** `HKCU\Software\Classes\leptone2e` = `URL:Tbeta2`, `URL Protocol` = `1`, `shell\open\command` = `"…\Programs\Tbeta2\bin\tbeta2.exe" "%1"`. `Start-Process "leptone2e://from-shell?q=%C3%A7"` (kabuk, kayıt defterinden) çalışan sayfaya `app.opened` ile geldi: değerin varlığı yetiyor. Windows adresi `leptone2e://from-shell/?q=%C3%A7` diye normalleştiriyor (`/` ekliyor). Kaldırma (`msiexec /x` 0) anahtarı, program klasörünü ve kısayolu siliyor.
- **Tek kopya:** ilk başlatmanın argümanı `launchArgs()`'ta (`leptone2e://first?x=1`); ikinci başlatma ~1 sn'de 0 ile bitti, argümanları ilk kopyaya `app.opened` ile ulaştı; süreç ve pencere tek kaldı (dört tur). Boşluklu argüman tırnaklıyken tek parça geliyor (`"quoted arg"`); PowerShell 5.1'in `Start-Process -ArgumentList` dizisi tırnaklamadığı için ilk denemede ikiye bölünmüştü. İlk denemede ikinci kopya bir kez `exit 1` verdi (sayfada `app.args` izni yokken); sonraki dört başlatmada tekrarlanmadı. `app.args` izin gerektiriyor — yeni projenin izinlerinde yok.
- **Pano:** girdi yokken `readText` → `NotAllowedError`; pencereye gerçek tıklamadan (`SendInput`, pencere önde) hemen sonra dışarıdan konan `dışarıdan çğüş 21` okundu; 7 sn boşta kalınca yine `NotAllowedError`. `writeText`'in yazdığı metin `Get-Clipboard`'da kod noktası kod noktası aynı. **Düzeltildi:** pencere odakta değilken `writeText` odak bekliyordu (4 sn'de bitmedi; bekleme Wayland içindi). Artık WebView2'de (`chrome.webview` her zaman var, ölçüldü) beklemiyor: odaksız pencereden yazılan metin panoya ulaştı (önce pano `baska bir metin`'e çekildi).
- **Pencere: küçük ekran, simge, kendi başlık çubuğu, yerel menü, sayfaya uyan başlık (2026-10-21, Windows'ta ölçüldü):**
  - *Küçük ekran:* mantıksal 1280 × 800 ya da daha küçük ekranda (bir yönü yeter; %150'deki 1920 × 1080 da sayılır) pencere çalışma alanına sığdırılıp ortalanıyor; büyük ekranda sığmayan da öyle (`window.zig` `place`, testler). Ölçüldü: 1024 × 768 ekranda 1200 × 800 istenen pencere 0,0'da 1024 × 728 (görev çubuğu dışı alanın tamamı), büyütülünce istemci alanı tam çalışma alanı. Linux: X11 penceresi zaten ortalanıyordu; Wayland'de yeri bileşimci seçer (protokol izin vermez).
  - *Başlıkta logo:* şablonun derlemesi exe'ye 1 numaralı ikon kaynağını gömüyor (`bundle.icon` ya da Lepton'ınki; CLI `-Dicon`, Zig'in kendi kaynak derleyicisi — mutlak yolu `BadPathName` ile reddettiği için ikon betiğin yanına kopyalanıyor), pencere sınıfı büyük ve küçük ikonu ayrı yüklüyor. Ölçüldü: exe'de 1 ikon, sınıfın iki ikonu da dolu, başlık çubuğunda Lepton'ın logosu (ekran görüntüsü). Linux'ta logo masaüstü girdisinin `Icon=`'ından (önceden vardı).
  - *Kendi başlık çubuğu:* `"window": { "decorations": false }` → `-Dwindow-decorations=false` → `view.setDecorations(false)`; `WM_NCCALCSIZE` başlık çubuğunu kaldırıyor, kenarlıklar kalıyor. Sayfa `dragRegion(el)` / `startDragging()` (`window.start_drag`, `WM_NCLBUTTONDOWN` gönderilmeden kuyruğa konuyor) ya da CSS `app-region: drag` (WebView2 `IsNonClientRegionSupportEnabled`). Ölçüldü (gerçek fare girdisi): istemci alanı pencerenin üstünden başlıyor (önce 31 px aşağıdaydı); sayfanın çubuğundan basıp 100,100 sürükleyince pencere 100,100 kaydı, içerikten basınca 0,0; çift tıklama büyüttü; sol kenardan 80 px yeniden boyutlandı. Linux: henüz yok (WPE 2.54'te süsleri kapatan çağrı yok), `window.start_drag` orada `failed`.
  - *Yerel menü:* `popupMenu(items)` → `window.menu` (`menu.zig` biçimi, zig ve TS testleri); Windows'ta `TrackPopupMenuEx`, istek işleyicisi döndükten sonra (`SetTimer`), cevap ertelenmiş. Ölçüldü: aşağı-aşağı-Enter ayırıcıyı atlayıp `9`, Esc `null`, menü penceresi açılıp kapandı. Sürüm derlemelerinde tarayıcının menüsü zaten kapalı, sayfa `contextmenu`'de kendi menüsünü çizebilir; Linux'ta yerel menü yok (`failed`).
  - *Yeni: başlık çubuğu sayfayı izliyor* (Tauri/Electron'da elle ayarlanır): enjekte edilen betik `<meta name="theme-color">`'u (motorun çözdüğü renk) ve `color-scheme`'i okuyup değiştikçe yalnız uygulamanın kendi sayfasından `postMessage` ile bildiriyor; çekirdek `DWMWA_USE_IMMERSIVE_DARK_MODE` ve Windows 11'de `DWMWA_CAPTION_COLOR` veriyor. Ölçüldü (DWM özniteliği + ekran görüntüsü): şablonun `color-scheme: dark`'ı → koyu; sayfa `light` → açık; `theme-color #ffd700` → açık; `rgb(27 29 28)` → koyu; geri → koyu. Windows 10 yeni çerçeveyi etkinlik değişene dek çizmiyordu (ilk görüntü beyazdı) → `WM_NCACTIVATE` ile hemen çiziliyor (sonraki görüntü koyu). Windows 11'deki renk ölçülmedi (bu makine 10).
  - Testler: `zig build test` (Windows) 60/63 (3 atlandı), `cargo test` 349, API 21, Clippy Windows ve Linux hedefi 0; `invoke`/`menu`/`registry` Linux'a çapraz derlendi. Linux'ta koşulmadı.
- **`app.args` varsayılan izin (2026-10-21):** yeni projelerin `permissions`'ı `["app.name", "app.args"]` (test: `a_new_project_may_read_its_own_start_arguments`). Güvenlik: komut yalnız bu programa verilen argümanları ve sonraki başlatmaların devrettiklerini (son 8) okur, yalnız uygulamanın kendi sayfasına; yerleşik komutlar kayıtta hiç gizli sayılmıyordu, artık `app.args` sayılıyor (`registry.isPrivate`, test). Ölçüldü: izin listesine dokunulmamış yeni projede `launchArgs()` → `leptone2e://callback?code=GIZLI-7f3a91`; `LEPTON_RECORD` kaydında (144 bayt) sır yok, `LEPTON_RECORD_UNMASKED=1` kaydında (183 bayt) var; `lepton replay` maskeli kayıtta `kept app.args: private`, çıkış 0.
- **Yeni proje `biome check`'ten geçmiyordu (bulundu, düzeltildi):** gömülü çekirdeğin `cookie_shim.js`'i (6 hata) ve `src-lepton/icon.svg` (`<title>` yok). Şablonun `biome.json`'u artık `src-lepton/vendor`'ı dışarıda bırakıyor (Lepton'ın kodu, geliştiricinin değil; proje git deposu olmadığında `.gitignore` okunmuyor), simgeye `<title>Lepton</title>` eklendi (CLI'nin kopyası da). Yeni vanilla-ts: `biome check` 0, `tsc` 0. Windows'ta görüldü; Linux'ta aynı olmalı (dosyalar aynı), denenmedi.
- **`fs.watch` (yazıldı, ölçüldü):** `plugin-fs/zig/fs_windows_watch.zig`, `ReadDirectoryChangesW` (çakışmalı okuma, döngünün her turunda bekletmeden boşaltılıyor; dizin kökün altında `OBJ_DONT_REPARSE` ile açılıyor). Sayfadan: `created a.md`, `modified a.md`, `renamedFrom a.md`, `renamedTo b.md`, `removed b.md`; PowerShell'in yazdıkları da geldi (`created alt`, `created alt/from-powershell.txt`, `modified …`, `removed …`, özyinelemeli). `zig test` 11/11; ağaca konan bir junction'ın hedefindeki yazma izlemeye düşmüyor, junction izlenemiyor (`denied`). Mutasyon: yeniden okumayı kaldırınca üç izleme testi, `MODIFIED` birleştirmesini kaldırınca bir test düştü — Windows tek yazmaya birden çok `MODIFIED` veriyor. Linux'tan farkı: izlenen dizinin adı değişirse bildirilmiyor; silinirse `gone`.

## Windows'ta Zig 0.17 (2026-10-21, ölçüldü)

- zvm 0.9.1 ile `zvm install 0.17.0` (zvm kurulunca varsayılanı 0.17 yapıyor; `zvm use 0.16.0` ile geri alındı — depo 0.16 ile biçimlenir).
- 0.17 ile: `zig build test` (Windows kökü) 60/63 (3 atlandı, 0.16 ile aynı); `plugin-fs` 11/11, `plugin-os` 3/3, `plugin-dialog` 2/2; `zig build invoke-check` derlendi.
- Şablon uygulama (`LEPTON_ZIG=…\0.17.0\zig.exe lepton build`) derlendi ve açıldı; `tools/ci/windows/measure.ps1` 0.16 derlemesiyle aynı sonucu verdi: koyu/açık başlık sayfayı izliyor, ikinci başlatma 0 ile bitti ve tek pencere kaldı, `WM_CLOSE` ile 0 çıkış. Kalan dört "FAIL" başlık/yazı rengi (`DWMWA_CAPTION_COLOR`/`TEXT_COLOR`): Windows 10'da `E_INVALIDARG` (0x80070057), yalnız Windows 11'de var.
- Bu makinede ayrıca: HEAD'den (`edc2ac7`) `cli-win32-x64` yeniden yerleştirildi (6 802 944 bayt), `api`/`plugin-clipboard`/`plugin-dialog` `prepublishOnly` 0; `beta.2` npm'de hâlâ boş.

## Windows Server 2025 CI (madde 4, ölçüldü, 2026-10-21)

Çalıştırma 39621873041 (`windows-2025`, Windows Server 2025 Datacenter 10.0.26100) geçti, 8 dk 41 sn:
- **Başlık rengi (Windows 11 tabanı):** sayfa `#ffd700` verince başlık çubuğunun pikseli `rgb(255, 215, 0)`, yazı siyah, koyu bayrak 0; `rgb(27 29 28)` verince piksel `rgb(27, 29, 28)`, koyu bayrak 1; açılışta (şablonun `color-scheme: dark`'ı) `rgb(32, 32, 32)`, koyu. Ekran görüntüsünde altın başlık, siyah yazı, Lepton logosu. Windows 11'de renk böylece ölçüldü.
- **Küçük ekran:** runner'ın ekranı 1024×768, çalışma alanı 1024×720: 1200×800 isteyen pencere 0,0'da 1024×720 (çalışma alanına sığdırıldı).
- **Simge:** sınıfın büyük ve küçük simgesi dolu, exe'de 1 simge.
- **Tek kopya + derin bağlantı:** iki ikinci başlatma (`leptonci://theme/…`) 0 ile bitti, tek pencere kaldı, bağlantı sayfaya `app.opened` ile ulaştı (sayfa başlığını değiştirdi). `WM_CLOSE` ile çıkış 0.
- **Paket:** `ci-app-0.1.0-windows-x86_64.msi` 245 760 bayt, `.zip` 190 356 bayt; `msiexec /i /qn` 0, kurulu exe'yle aynı denetimler geçti, `msiexec /x /qn` 0, `%LOCALAPPDATA%\Programs\ci-app` kalmadı.
- **İlk iki çalıştırmanın bulduğu:**
  - `lepton new --package-manager npm` npm'i bulamıyordu: Rust'ın `Command` yalnız `.exe` arıyor, Node'un npm'i `npm.cmd`. Bu makinede npm vite-plus'ın `.exe` kabuğu olduğu için hiç görünmemişti. Düzeltildi: `orchestrator/src/program.rs`, `PATHEXT` sırası.
  - `lepton new` Windows'ta "WPE WebKit" yazıyordu; düzeltildi, artık "WebView2".
  - Ölçümün kendi hatası: sayfanın DevTools portu runner'da açılmadı. Sayfa artık rengini derin bağlantıyla kendisi değiştiriyor (`tools/ci/windows/ci-theme.ts`).
  - Ölçümün kendi hatası: `DWMWA_CAPTION_COLOR`/`TEXT_COLOR` geri okunamıyor (`E_INVALIDARG`, Windows 10'da ve Server 2025'te; yalnız yazmak için belgelenmiş). Renk artık pikselden okunuyor.

### Eski not (yazılırken)

- `.github/workflows/windows.yml` (`windows-2025`): CLI, bu depodan `@lepton-desk/api` ile şablon uygulama (`deepLinks: ["leptonci"]`, `bundle.targets: ["zip", "msi"]`), pencere ölçümü, paketleme, MSI kur → aç ve ölç → kaldır (klasör kalmamalı). Rapor ve ekran görüntüleri `windows-2025` artifact'ında.
- `tools/ci/windows/`: `cdp.mjs` (DevTools ile sayfada ifade; `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port`), `window-facts.ps1` (yerleşim, simgeler, DWM 20/35/36, başlık pikseli, ekran görüntüsü), `measure.ps1` (`theme-color` `#ffd700` → başlık `0x0000D7FF`, yazı siyah, açık; `rgb(27 29 28)` → `0x001C1D1B`, yazı beyaz, koyu; tek kopya; kapanış). Renk denetimi başarılı okuma (`hr 0`) da istiyor: Windows 10'da başarısız okuma 0 döndürüp "siyah yazı"yı yanlışlıkla geçiriyordu.

## Linux'tan Windows paketi (madde 5, adım 1–2 yazıldı)

- `platform::System` (Linux/Windows): exe adı ve paket adındaki sistem hedefe göre; `packages_as(format, sistem)` MSI'yı Windows derlemesi için her makinede kabul ediyor, `deb`/`arch` yalnız Linux'ta Linux derlemesi için.
- `lepton package --windows` / `--linux`: derlemeye geçiyor; `bundle.targets` yoksa Windows derlemesi `zip`. Hedef bu makine değilse `--verify` derlemeden önce nedeniyle reddediliyor. Masaüstü girdisi yalnız Linux derlemesinde.
- Testler: Windows paketi testi artık her makinede koşuyor ve `zip` ile `msi`'yi yazıyor; `cargo test` 352 (önce 349), Clippy Windows ve Linux hedefi 0. **Linux'ta çalıştırılmadı:** `lepton package --windows` Linux'ta denenecek, çıkan MSI CI'da kurulacak (adım 3), bayt eşitliği ölçülecek (adım 4).

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

## Sıradaki (kullanıcı, 2026-10-21; limit yüzünden ertelendi)

1. **Linux'ta `failed` kalmasın:**
   - `window.decorations: false`: WPE'de başlık çubuğu kaldırılsın (önce WPE 2.54/2.56 API'sinde süsleri kapatan bir yol aranacak — `WPEToplevel`, xdg-decoration `client_side` isteği; yoksa Lepton'ın kendi WPE platformunda). Servo'nun X11 penceresinde `_MOTIF_WM_HINTS`.
   - `window.start_drag`: Wayland'de `xdg_toplevel_move` (basışın `serial`'ı gerekir), X11'de `_NET_WM_MOVERESIZE`.
   - `window.menu`: yerel menü — WPE menü çizmiyor; Lepton'ın kendi sağ tık menüsü (`window/linux/chrome.zig`) ya da bir xdg-popup.
   - Başlık çubuğunun sayfayı izlemesi Linux'ta da (bileşimci izin veriyorsa; yoksa nedenini yaz).
2. **Açık kalanların hepsi** (aşağıdaki liste ve bu dosyadaki "ölçülmedi" notları).
3. **Windows'ta Zig 0.17:** zvm ile 0.17 kurulup `zig build test`, şablon uygulama, araçlar 0.17 ile de geçmeli (Linux'ta ikisi geçiyor; Windows'ta yalnız 0.16 denendi). Durumu aşağıda, "Windows'ta Zig 0.17".
4. ~~**Windows 11 ve Windows Server 2025 uyumu, CI'da ölçülür**~~ — ölçüldü (aşağıda, "Windows Server 2025 CI"); çerçevesiz pencere, sürükleme, yerel menü ve başlık çubuğunun üç düğmesi de artık iş akışında (aşağıda, "Başlık çubuğunun üç düğmesi"). (bu makine Windows 11 gereksinimlerini karşılamıyor; kurulmayacak, atlatılmayacak): GitHub Actions `windows-2025` (Server 2025, derleme 26100) üzerinde bir iş akışı şablon uygulamayı derleyip açar ve ölçer — başlık rengi (`theme-color` verilince `DwmGetWindowAttribute(DWMWA_CAPTION_COLOR)` beklenen renk mi, ekran görüntüsü artifact olarak), koyu/açık, simge, küçük ekranda yerleşim, çerçevesiz pencere ve sürükleme, yerel menü, tek kopya, MSI kurulum/kaldırma. Önce Server 2025'te `DWMWA_CAPTION_COLOR`'ın gerçekten çalıştığı ölçülecek; çalışmıyorsa nedeni yazılır. Server 2025'e ya da Windows 11'e özgü fark çıkarsa düzeltilir (Windows 10'da ölçülenler bozulmadan).

5. **Linux'tan Windows paketi, yalnız `.exe` değil** (adım adım): `lepton package --windows` Linux'ta `.zip` ve `.msi` yazar — ikisinin yazıcısı da saf Rust (`zip.rs`, `installer_db.rs` + `cfb`/`cab`), simge Zig'in kaynak derleyicisiyle, WebView2 başlığı depoda.
   1. Paket çalışan makineye değil hedefe göre: `platform::bundle_os`/`executable` hedeften (dosya adı `windows`, `.exe`), `packages_as` MSI'yı hedef Windows olduğunda Linux'ta da kabul eder.
   2. `--verify` Linux'ta Windows paketini çalıştıramaz: açıkça reddeder ("doğrulandı" demez). Wine önerilmez (WebView2 orada güvenilir değil).
   3. Doğrulama CI'da (madde 4'teki `windows-2025` iş akışı): Linux'ta üretilen MSI'yı orada kurar, açar, ölçer, kaldırır.
   4. Tekrarlanabilirlik: aynı proje Windows'ta ve Linux'ta paketlenince `.zip` ve `.msi` bayt bayt aynı olmalı (ölçülecek).
   5. Sonra: imzalama (sertifika gelince), arm64 Windows.
   - **Ters yön (Windows'tan Linux paketi) sonra:** Linux çekirdeği WPE'nin sistem kitaplıklarına bağlanıyor, `.deb`/pacman bağımlılıkları `dpkg-query`/`pacman` ile bulunuyor; ayrı bir tasarım ister. Çoğu framework iki yönü de yapamıyor.

Kullanıcı Linux'ta çalıştırıp düzeltecek; Windows'ta ölçülenler bozulmamalı.

### Kararlar (2026-10-21)

- **Cam ve macOS benzeri görünüm:** taklit ya da CSS kütüphanesi yok, sarmalayıcı yok. İki parça, ikisi de iyi yapılacak: (1) **sistem malzemesi** — `window.material` ile her sistemin kendisi: Windows 11 Mica/Acrylic (`DWMWA_SYSTEMBACKDROP_TYPE`), Linux Wayland'de `ext_background_effect_manager_v1` bulanıklığı (bileşimci sunuyorsa; COSMIC'te var, ölçüldü: yalnız `blur`, kırılma/ton yok); sunulmazsa pencere opak kalır ve sayfa bunu bir olayla öğrenir. (2) **Lepton'ın kendi camı** — kendi çizicisinde gerçek kırılma/parlama; önce tasarım belgesi. Ölçüldü: WPE `backdrop-filter: blur()` ve `url(#svg)`'yi kabul ediyor (çizimi ölçülmedi), Servo `backdrop-filter`'ı hiç tanımıyor.
- **WPE'de süs, taşıma, menü (ve cam):** WPE 2.54'ün Wayland platformu her zaman `MODE_SERVER_SIDE` istiyor, istemci tarafı süs çizemiyor ve `xdg_toplevel`'ı vermiyor (`WPEToplevelWayland.cpp` 2.54). Karar: **Lepton'ın kendi WPE platformu** (`render/webview/platform/lepton_display.zig`, WebKit yaması değil, `WPE_PLATFORM=lepton`) tamamlanacak; sayfa Lepton'ın kendi Wayland penceresine çizilecek. Adım adım; WPE'nin kendi platformu yedek kalır. Servo'nun X11 penceresi zaten Lepton'ın: orada `_MOTIF_WM_HINTS`, `_NET_WM_MOVERESIZE`, kendi menü penceresi.


## Açık kalanlar

Servo yalnız Linux içindir ve öyle kalacak: Windows'ta motor WebView2'dir (Chromium tabanlı, sistemle gelir, Microsoft günceller). `--servo` başka sistemde reddedilir.


- Windows: simgenin 256 px çerçevesi kabukta (Gezgin'in büyük simgeleri) gözle bakılmadı; `fs.watch` ve panodaki düzeltme Linux'ta yeniden koşturulmadı (Linux yarıları değişmedi).
- Servo: Wayland'de XWayland üzerinden. Servo kapanışta sürecin sonuna bırakılıyor (`_exit`): kendi kapanışı worker'ları süresiz bekliyor.
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
- **`document.cookie` (ölçüldü, çözüldü):** WebKit (`Document::isCookieAverse`) ve Servo (`is_cookie_averse`) HTML standardı gereği http(s)/ftp/file dışındaki şemadaki belgeye çerez vermiyor; köken yaması bunu değiştirmez, WPE dağıtımın paketi olduğu için yamalanamaz. Transport artık yalnız uygulamanın kendi sayfasında ve yalnız ağ şeması dışındaki adreste `document.cookie`'yi tanımlıyor (`zig/src/render/webview/cookie_shim.js`, `localStorage`'da `__lepton.cookies`; RFC 6265'in betik kuralları, `cookie_shim.test.mjs` `zig` iş akışında çalışıyor). Ölçüldü: WPE ve Servo'da bir çalıştırmada yazılan çerez sonrakinde okundu. Windows'ta ölçülmedi (sayfa `http://lepton.localhost`, şim kurulmaz).
- **Dev sunucusundaki sayfada gerçek çerezler kalıcı değildi (ölçüldü):** `lepton dev`'de (`http://127.0.0.1:5173`) çerez yazılıyor ama sonraki açılışta iki motorda da yoktu; `localStorage` kalıyordu, veri klasöründe çerez dosyası yoktu.
  - WPE: ağ oturumu veri klasörüyle kurulsa da `webkit_cookie_manager_set_persistent_storage` çağrılmadıkça çerezler yalnız bellekte. Artık `$APPDATA/cookies.sqlite` (klasör 0700). Ölçüldü: ikinci açılışta önceki çerez okundu. Eski ABI yolu (`-Dwpe-abi=legacy`, 2.52) ağ oturumu kurmuyor; bu makinede 2.54 olduğu için ölçülemedi.
  - Servo: `cookie_jar.json`'ı yalnız `CoreResourceMsg::Exit`'te yazıyor, kurucu onu bütün script iş parçacıkları birleştikten sonra gönderiyor; çekirdek bu beklemeyi `_exit` ile atladığı için hiç yazılmıyordu. `servo/patches/servo` (servo 0.6.0 + `SiteDataManager::write_network_state_and_stop`) ve `lepton_servo_write_state`: çekirdek Servo'yu bırakmadan önce çağırıyor. `servo-bridge` çalıştırma 39576853066 bütün adımlarıyla geçti (SHA-256 `86a97abd…f7ec`, 20 fonksiyon), yerleştirildi. Ölçüldü: `dev --servo`'da ikinci açılışta önceki çerez okundu, `servo/cookie_jar.json` yazıldı; `run --servo`'da şimin çerezi de kalıyor; her turda `✔ app`, kalan süreç yok, `/dev/shm` boş. Paketteki eski kitaplıkla bu çekirdek Servo'ya bağlanmaz: yayımlarken bu kitaplık yerleştirilmeli.

## 2026-10-21 öğleden sonra: Linux eşitliği

- **Servo'nun X11 penceresi (ölçüldü, gerçek fareyle):** `window.decorations: false` → `_MOTIF_WM_HINTS` (COSMIC başlık çubuğunu kaldırdı, ekran görüntüsü); `window.start_drag` → `_NET_WM_MOVERESIZE` (sayfanın çubuğundan sürükleyince pencere 228,118'den 219,171'e geçti; pencere yöneticisi bırakmayı yuttuğu için bırakma sayfaya Lepton'dan veriliyor); `dragRegion`'ın çift tıklaması büyüttü/geri aldı.
- **Sağ tık Servo'da sayfaya ulaşmıyordu (bulundu, düzeltildi):** X11 penceresi sağ basışı native yolun çerçeve menüsüne veriyordu. Artık `own_chrome` yalnız native yolda; Servo'da `down 2`, `contextmenu`, `up 2` geliyor.
- **`window.menu` Servo'da (yazıldı, ölçüldü):** `servo/menu_x11.zig` — imleçte override-redirect pencere, Cairo ile çizim (native çerçeve paleti), işaretçi ve klavye tutuşu; açan basışın bırakması seçmez, dışarı basış ve Esc kapatır (`null`), oklar/Home/End/Enter/Space; devre dışı ve ayırıcı seçilmez. Uygulama odağı kaybedince (`FocusOut`, `_NET_WM_STATE_FOCUSED` gidince) ya da gizlenince kapanır (Tauri/Electron gibi). İşaret ✓ yazı değil çizgi: `sans-serif` burada Noto Sans, U+2713 yok, Cairo'nun basit yazı API'si yedek fonta geçmiyor (ölçüldü: işaret görünmüyordu). Kullanıcı denedi: seçim, dışarı tıklama, klavye, işaret, Alt+Tab'da kapanma.
- **X11 olayları:** pencereye katman kancası (`overlay`); odak değişimi maskesi; `hasState`.
- **Zig biçimi:** depo 0.16'nın `zig fmt`'iyle biçimlenir; 0.17'ninki 0.16'da olmayan yerleşikleri yazıyor (`@intFromEnum` → `@backingInt`, ölçüldü), çalıştırılmamalı. Önceden biçimsiz 10 dosya biçimlendi; `zig` iş akışına 0.16 biçim denetimi eklendi.
- **Başlık çubuğu sayfayı izlesin (Linux):** COSMIC X11'de `_GTK_THEME_VARIANT`'ı yok sayıyor (iki görüntü 0 piksel fark); Wayland'de protokolü yok. Lepton'ın kendi çizdiği başlık çubuğuyla gelecek (`docs/wpe-platform.md` adım 5); Servo için aynı çizim katmanı gerekir.
- **Yayın sırası (kullanıcı kararı):** 0.1.9-beta.2 kendi WPE platformunu beklemez; WPE'de `decorations: false`, `start_drag`, `window.menu` belgelerde "Linux WPE'de henüz yok" diye yazılır, kendi platform beta.3'e.
- **Kendi WPE platformu:** plan `docs/wpe-platform.md`. Bugün yalnız `WPELeptonDisplay` seçiliyor (ölçüldü, `zig build platform-check`).

## Başlık çubuğunun üç düğmesi (2026-10-21/23, Windows'ta ölçüldü)

- `windowControls(bar)` (`@lepton-desk/api/window`): `[data-window-control="minimize|maximize|close"]` düğmeleri; büyütülmüşken çubukta `data-maximized`. İzinler: `window.minimize`, `maximize`, `unmaximize`, `state`, `close`.
- Gerçek fareyle (`SendInput`) ölçüldü, `tools/ci/windows/measure.ps1`:
  - **Sistemin düğmeleri** (çerçeveli pencere; yerleri `WM_GETTITLEBARINFOEX`'ten — `WM_NCHITTEST` DWM'nin çizdiği düğmeleri değil eski düzeni söylüyor, Not Defteri'nde de): küçült → `IsIconic`, büyüt → `IsZoomed`, yeniden → geri alındı, kapat → çıkış 0.
  - **Sayfanın düğmeleri** (`decorations: false`): aynı dört sonuç.
  - Windows 10 22H2 (bu makine): ikisi de geçti. Server 2025 (CI 39627630003, 39629060471): ikisi de geçti.
- **CI 39629060471'de düşen iki adım ölçümün hatasıydı, uygulamanın değil:** .NET'in `MainWindowHandle`'ı pencere bulunduktan 3 sn sonra 35×19'luk bir açılır pencereye döndü, betik çöktü ve kurulu uygulama açık kaldı; çerçevesiz adımın başlattığı uygulama (aynı kimlik) tek kopya kuralıyla argümanını ona verip çıktı, ölçülen pencere eski çerçeveli kopyaydı (`client top - window top = 31`). Düzeltildi (`8859993`): pencere başlatılan sürecin `LeptonWindow` sınıflı penceresi (`EnumWindows`), açılışta çalışan kopyalar kapatılıyor, betik düşerse uygulama da kapatılıyor. Bu makinede eski kopya açıkken çerçevesiz ölçüm baştan sona geçti. CI 39940123813 (`8859993`): üç adım da geçti — pencere, MSI kur/aç/kaldır (klasör kalmadı), çerçevesiz pencere.
- **Linux: ölçülmedi.** `tools/ci/linux/window-controls.sh` (Servo X11, `_NET_WM_STATE`) yazıldı, hiç çalıştırılmadı ve hiçbir iş akışında yok. WPE'de `decorations: false` yok, sayfanın çubuğu bileşimcinin çubuğunun altında kalır; düğmeler yine çalışmalı, elle denenecek: çubuğun sağındaki üç düğme sırayla küçültmeli, büyütmeli, geri almalı, kapatmalı (çıkış 0).

## Windows native yolu (2026-10-23 başladı)

Kararlar `docs/plans/windows.md`: pencere Win32, metin DirectWrite; çizici Vulkan → D3D11 → OpenGL 3.3 (sahne çizicisi 0.2.0 betalarına).

1. **CLI reddi** (yapıldı, aşağıda "Eksikler" Windows 1).
2. **Win32 penceresi `window/windows/`'a taşındı** (yapıldı): `render/webview/webview2/window.zig` → `window/windows/window.zig`, WebView2 yolu ve gelecek native yol aynı pencereyi kullanacak. Windows başlıkları tek çeviri: `src/c/c_webview2.h` → `c_windows.h` (iki ayrı `<windows.h>` çevirisi iki ayrı `HWND` tipi verir); `window/windows/win32.zig` ve `webview2/c.zig` aynı modülü okuyor. WebView2.h yalnız tip, çalışma zamanı yüklenerek bulunuyor: native derlemeye bağlantı eklemez.
   - Ölçüldü (Windows 10 22H2): `zig build test` (Windows kökü) 60/63 (3 atlandı, öncekiyle aynı). Yeni çekirdekle derlenen CI uygulaması `measure.ps1` ile çerçevesiz ve çerçeveli: bütün denetimler geçti (tema koyu/açık, yerel menü, sürükleme, sol kenar, sistemin ve sayfanın üç düğmesi, kapatma 0).
   - **`zig build`'in yazdığı 10 satır `IO_REPARSE_TAG_NOT_HANDLED` (0xc0000279), ölçüldü ve düzeltildi:** taşımadan önce de vardı. Kaynağı kullanıcı PATH'inde klasör yerine dosya olan bir girdi: `%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe` (0 baytlık App Execution Alias, yeniden ayrıştırma etiketi `0x8000001b`). O girdi PATH'ten çıkarılınca 0 satır, bütün WindowsApps girdileri çıkarılınca 0, olduğu gibi 10. `zig build --help` de 10 veriyordu → yapılandırma aşaması: `build.zig`'deki iki pkg-config yoklaması (`egl`, `vulkan`) Linux'a bağlı değildi ve Windows'ta `findProgram("pkg-config")` PATH'i tarıyordu. İkisi artık yalnız Linux'ta (öbür bütün yoklamalar gibi); Windows'ta 0 satır, testler 60/63. Projelerin `lepton-build.zig`'inde PATH araması yok. Bu makinedeki PATH girdisi ayrıca kullanıcının düzeltmesi için (aşağıdaki komut).
3. **Sırada:** `Window.Backend`'e `win32` kolu (`window/window.zig`), native yolun Windows'ta derlenmesi (bugün `root.zig` Linux pencere katmanına uzanıyor), kareyi pencereye basma, DirectWrite metni.

## Eksikler (2026-10-23; iki tarama, her madde kodda doğrulandı)

Kanıt satırları tarama anındaki kod içindir. "Kayıtlı" = bu dosyada zaten vardı.

### Windows'ta (Linux'ta olup Windows'ta olmayan)

Engelleyen:
1. ~~**Native çizim yolu Windows'ta yok, CLI yine de seçtiriyor.**~~ **Düzeltildi (2026-10-23):** gerekçe tek yerde (`platform::native_path`). Windows'ta `lepton new --template …` hedef verilmezse webview (sihirbaz sormuyor, "webview" yazıyor), `--target native` hiçbir şey yazılmadan reddediliyor; `build --native` (ve `--windows` için native, dry run dahil), `run --native`, `dev --native` gerekçesiyle reddediliyor; `build --linux --native` çalışıyor. Bu makinede sürüm ikilisiyle ölçüldü (çıkışlar 1/0/1/0/1/1, yeni projenin `renderPath`'i `webview`); etkileşimli sihirbaz yolu ayrıca denenmedi. Testler: `cargo test` 358, Clippy Windows ve Linux hedefi 0. Native yolun kendisi (Win32 + DirectWrite) yazılıyor: `docs/plans/windows.md`.
2. **`window.open` açılır penceresi `webPermissions`'ı ve indirmeleri atlıyor.** `webview2/popup.zig` yalnız `WebResourceRequested`, `DocumentTitleChanged`, `WindowCloseRequested`, `NavigationStarting`, `NewWindowRequested` bağlıyor; `PermissionRequested`/`DownloadStarting` yok. Linux'ta açılır pencere de politikadan geçiyor (`features.zig`, `permissions.watchView`). Koddan okundu, ölçülmedi.
3. ~~**`lepton info` WebView2 yokken "native builds only" diyor**~~ **Düzeltildi:** Windows'ta "nothing builds here until the engine is installed" (WebView2'siz makinede ölçülmedi; bu makinede WebView2 var).

Eksik:
4. Derin bağlantı `dev`/`run`'da ve `.zip`'te kaydolmuyor; yalnız MSI `HKCU\Software\Classes` yazıyor (`desktop_entry::announce` Linux dışında dönüyor).
5. Sayfanın `console`'u terminale gelmiyor (Linux Debug'da `write_console_messages_to_stdout`; `webview2/view.zig`'de karşılığı yok).
6. Bildirimler WebView2'nin kendi arayüzünde; `setApplication`'ın adı/kimliği kullanılmıyor, hangi uygulamaya atfedildiği (AUMID) ölçülmedi.
7. İzin türleri: `webview2/permissions.zig` `kindOf` yalnız mikrofon, kamera, konum, bildirim; `pointer-lock`, `device-info`, `media-keys`, `storage-access`, `xr` için `allow` etkisiz. `navigator.permissions.query` politikadan cevaplanmıyor.
8. Oturum kapanışı/kapatma: sürüm derlemesi Windows alt sisteminde; `termination.zig` `SetConsoleCtrlHandler`'a dayanıyor, pencere `WM_QUERYENDSESSION`/`WM_ENDSESSION`'ı işlemiyor. Ölçülmeli.
9. Motor kurulum önerisi yok (Linux paket yöneticisini öneriyor; Windows yalnız adres yazıyor).
10. Yoklama araçları (`webview-check`, `engine-caps`, `platform-check`…) Linux'a özel; Windows'ta yalnız `webview2-check`.
11. `windows_tests.zig` `record`, `replay`, `page_replay`, `bridge`, `transport`, `assets`, `single_instance`, `activation`, `webview2/permissions` (kendi testi var) dosyalarını kapsamıyor: uçtan uca ölçüldüler ama birim testleri Windows'ta koşmuyor.
12. `lepton`'ın çocukları Windows'ta `taskkill /T /F` ile bitiyor (Linux'ta SIGTERM).
13. Windows'ta yapılan `tar.gz`'de ikili `+x` almıyor (`archive.rs:254`, yorum da eski).
14. Dev sunucusu sayfasında çerezlerin kalıcılığı Windows'ta ölçülmedi.
- Bilerek: Servo yalnız Linux; systemd scope/masaüstü girdisi Linux'a özel; MSIX/imza sertifika bekliyor; arm64 yok.
- Eski yorum: `plugin-fs/zig/plugin.zig:280` "Windows answers `failed`" diyor, `fs.watch` Windows'ta var.

### Linux'ta (Windows'ta olup Linux'ta olmayan)

Kayıtlı (yukarıda): WPE'de `decorations: false`, `start_drag`, `window.menu` → `failed` (kendi WPE platformu, beta.3); başlık çubuğunun sayfayı izlemesi; Linux'tan Windows paketi ölçülmedi; Servo'da izinler, pano, diyaloglar.

Yeni:
1. **WPE'de pencere boyutu küçük ekrana sığdırılmıyor:** `wpe_view.zig` `resized` istenen boyutu çalışma alanına bakmadan veriyor (Windows `place`/`isSmall`, Servo ve Lepton'ın kendi pencereleri sığdırıyor). Ölçülmedi.
2. **Servo penceresi uygulama kimliğini almıyor:** `servo/view.zig` `X11Window.open`'a `app_id` vermiyor, `WM_CLASS` varsayılan `dev.lepton.app`; masaüstü girdisinin `StartupWMClass=<identifier>`'ıyla eşleşmez, simge ve dock gruplaması kaçar. `_NET_WM_ICON` hiç yok.
3. **`bundle.icon` Linux paketine gitmiyor:** yalnız `.ico`, yalnız Windows; Linux hep `src-lepton/icon.svg`.
4. **CSS `app-region: drag` yalnız WebView2'de**; api README platform belirtmiyor.
5. **Servo'da çerçevesiz pencere kenardan boyutlanmıyor:** yalnız taşıma isteniyor (`_NET_WM_MOVERESIZE` yön 8).
6. **WPE'de `dragRegion` her basışta yakalanmamış bir ret bırakıyor** (`window.ts:111` `void startDragging()`, cevap `failed`).
7. **Servo menüsünde `&` olduğu gibi çiziliyor** (Windows'ta erişim tuşu; README örneği `&Kopyala`).
8. **`windowControls` Linux'ta ölçülmedi** (yukarıda).
9. Belgeler: api README `start_drag`/`menu`/çerçevesiz için "(Windows)" diyor, Servo'yu anmıyor ve "Linux WPE'de henüz yok" demiyor; `window.ts` "Linux for now", `window_shape.rs`/`lepton-build.zig` "(Windows)" — Servo'da hepsi var.
10. Küçük: Linux derlemesi de `-Dicon` alıp kullanılmayan `.ico` yazıyor; `wpe_view.zig`'de `map`'in belge yorumu `setDecorations`'ın üstüne kaymış.

**Windows değişiklikleri Linux'u bozdu mu?** Koddan: hayır. `program::resolve` Linux'ta adı değiştirmeden döndürüyor (test var); `invoke.zig`'in yeni 10/11 komutları geri çağrı yoksa `failed` (Linux testi var); `main.zig`'deki tek değişiklik `@hasDecl` korumalı. Davranış değişikliği: `bundle.targets`'taki `msi` artık `--windows` olmayan her derlemede (Linux'ta da) nedeniyle reddediliyor. Linux'ta derlenip koşturulmadı.
