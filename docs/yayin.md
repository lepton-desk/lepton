# npm yayını: `@lepton-desk/*`

Şu anki sürüm: **0.1.9-beta.2** (0.1.0–0.1.9-beta.1 yayımlandı; `create-lepton-app` 0.1.4 ile çıktı). Sürüm artırımı tek komut: `node tools/release-version.mjs <sürüm>`. `Cargo.toml` (CLI sürümünü
derlemede buradan okur: `--version`, komut başlıkları, yeni projelerin `@lepton-desk/*` sürümleri),
`Cargo.lock`, dokuz npm paketinin `version`'ı, `cli`'nin `optionalDependencies`'i (iki platform paketi), eklentilerin
`^<sürüm>` `peerDependencies`'i, `create-lepton-app`'in `@lepton-desk/cli`'si, `lepton update`'in
şablon geçmişi (`assets/history/<sürüm>/` + `RELEASES`), AUR `pkgver`'i (yalnız kararlı sürümde; ön sürüm AUR'a gitmez) ve bu dosyanın sürümü.
Yayından sonra `node tools/release-version.mjs aur`: `-bin`'in sha512'si npm'den, kaynak paketin
commit'i HEAD'den, `.SRCINFO`'lar yeniden. Platform paketini `stage.mjs` yazar.

Sürüm hazırlığının nerede durduğu, neyin ölçüldüğü ve Windows'ta neyin ölçülmeyi beklediği: `docs/durum.md`.

Yayımlanacaklar, bu sırayla: `@lepton-desk/cli-win32-x64` (**Windows'ta**, aşağıda) → `@lepton-desk/cli-linux-x64` → `@lepton-desk/cli` →
`@lepton-desk/api` → eklentiler (`plugin-os`, `plugin-clipboard`, `plugin-fs`, `plugin-dialog`; `api`'ye eş bağımlı) → `@lepton-desk/servo-linux-x64` (deneysel; kimse ona bağlı değil, projeler `-D` ile kurar) → `create-lepton-app` (en son; `@lepton-desk/cli`'nin aynı sürümüne bağlı). Platform paketi önce gider; `cli` ona `optionalDependencies` ile bağlı.

**Servo kitaplığı** (0.1.9-beta.2'den): CI derler (`servo-bridge` iş akışı, ~12 dk). O çalıştırmanın `liblepton_servo` artifact'ını indirip yerleştirin; betik ELF'i denetler, boyutu ve SHA-256'yı yazar (CI raporundaki `sha256:` satırıyla aynı olmalı):

```bash
gh run download <run-id> -n liblepton_servo -D /tmp/servo
node tools/stage-servo.mjs /tmp/servo/liblepton_servo.so.xz
```

## 1. Sizin kararınız gerekenler (ön kontrol bunlarsız geçmez)
- ~~Lisans metinleri~~ — eklendi: `LICENSE-MIT` (2026 Lepton Desk Contributors) ve
  `LICENSE-APACHE` (apache.org'dan). Ön kontrol bunları üç pakete kopyalar.
- ~~Depo adresi~~ — `https://github.com/lepton-desk/lepton` oluşturuldu (herkese açık, varsayılan dal `trunk`).

## 2. Ön kontrol (hiçbir şey yayımlamaz)

```bash
tools/npm-preflight.sh
```

Sürüm eşitliği, npm'de o sürümün boş olması, lisanslar, Rust test/clippy, ikilinin
`cli-linux-x64`'e konması, `@lepton-desk/api` derleme/denetim/test, `cli` testleri ve her
tarball'ın içeriği. Sonu `preflight: ready to publish <sürüm>` olmalı.

## 3. Giriş

```bash
npm login
```

```bash
npm whoami
```

## 4. Yayın (2FA açıksa her komuta `--otp=<kod>` ekleyin)

Ön kontrolün son satırı dist-tag'i söyler: düz sürüm `npm publish` (`latest`); `0.2.0-beta.N` için
her komuta `--tag beta`, `1.0.0-rc.N` için `--tag next` (npm 11 ön sürümü etiketsiz yayımlamaz).
Eklentilerin `peerDependencies` (`^<sürüm>`) ve `cli`'nin `optionalDependencies`'i de sürümle birlikte artar.

Yayın iki makineye bölünür; aynı commit'ten (`git pull`). **Önce Windows**, sonra Linux: `cli` iki platform
paketine, `create-lepton-app` `cli`'ye bağlı. Eklentilerin dördü de Windows'ta çalışır ve testlerini geçer;
ama `plugin-os` (`uname` / `RtlGetVersion`) ve `plugin-fs` (`openat2` / `NtCreateFile`) her sistem için ayrı Zig
taşır ve `prepublishOnly` yalnız yayımlandığı sistemin yarısını test eder — bu yüzden Linux yarısı test edilsin
diye Linux'tan yayımlanırlar (Windows yarısı Windows'ta `pnpm test` ile).
Ön kontrol Windows'tan yayımlananları (`from_windows`) "published from Windows" diye geçer.

### 4a. Windows (`D:/lepton`, PowerShell 5.1 — `&&` yok, komutlar ayrı ya da `;` + `if ($?)`)

Hazırlık:

```powershell
cargo build --release --bin lepton
```

```powershell
node packages/cli/scripts/stage.mjs
```

```powershell
cd D:/lepton/zig; if ($?) { zig build invoke-check }
```

```powershell
cd D:/lepton; foreach ($p in 'cli-win32-x64','api','plugin-clipboard','plugin-dialog') { Copy-Item LICENSE-MIT, LICENSE-APACHE "packages/$p/" }
```

Yayın, bu sırayla (`api` ve eklentiler yayından önce kendi `prepublishOnly`'lerini çalıştırır: derleme + denetim + test):

```powershell
cd D:/lepton/packages/cli-win32-x64; if ($?) { npm publish --tag beta }
```

```powershell
cd D:/lepton/packages/api; if ($?) { npm publish --tag beta }
```

```powershell
cd D:/lepton/packages/plugin-clipboard; if ($?) { npm publish --tag beta }
```

```powershell
cd D:/lepton/packages/plugin-dialog; if ($?) { npm publish --tag beta }
```

`stage.mjs` ikilinin `lepton --version`'ının paket sürümüyle aynı olduğunu denetler.

### 4b. Linux (EndeavourOS)

```bash
tools/npm-preflight.sh
```

Windows'tan çıkan dört paketi "published from Windows" diye geçmeli, sonu `preflight: ready to publish`.

```bash
cd packages/cli-linux-x64 && npm publish --tag beta
```

```bash
cd packages/cli && npm publish --tag beta
```

```bash
cd packages/plugin-os && npm publish --tag beta
```

```bash
cd packages/plugin-fs && npm publish --tag beta
```

```bash
cd packages/create-lepton-app && npm publish --tag beta
```

Kararlı sürümde (`latest`) aynı komutlar `--tag beta` olmadan.

`publishConfig.access: public` her pakette var; `--access public` gerekmez.
- `E404 Not Found - PUT` paket yokluğu değil, oturum yok demek (`npm whoami` 401 verir): `npm login`.
- `E409 Cannot publish over previously staged version` aynı sürümün ilk yayını hâlâ işleniyor demek
  (0.1.5'te plugin-dialog: 409'dan 2 dk sonra yayında göründü). Tekrar yayımlamayın; birkaç dakika
  bekleyip `npm view <paket>@<sürüm> version` ile bakın.
`api` yayından önce kendi `prepublishOnly`'sini çalıştırır (derleme + denetim + test).

## 5. Doğrulama (boş bir dizinde)

```bash
npm view @lepton-desk/cli version
```

```bash
npx @lepton-desk/cli@latest --version
```

Beklenen: `lepton <sürüm>` (yukarıdaki "Şu anki sürüm").

## 6. Geri alma
- 72 saat içinde: `npm unpublish @lepton-desk/<paket>@<sürüm>` (aynı sürüm bir daha kullanılamaz).
- Sonrası: `npm deprecate @lepton-desk/<paket>@<sürüm> "<neden>"`.

## Yayından sonra (benim işim)
- Yeni sürüm kayıt defterinde görünür olunca (ilk yayında ~5 dk sürdü; ilk kez yayımlanan bir
  paketin pnpm'in okuduğu kısaltılmış belgesi — `Accept: application/vnd.npm.install-v1+json` —
  sürüm adresinden ~3 dk sonra geldi) `npx` ve yeni bir
  proje `pnpm install` + `lepton run` ile doğrulanır.
- Diğer platformlar: kendi makinelerinde/CI'da `cargo build --release` + `stage.mjs`, sonra
  `cli`'nin `optionalDependencies`'ine eklenip `cli` yeni sürümle yeniden yayımlanır.
