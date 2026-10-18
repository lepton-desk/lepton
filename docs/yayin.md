# npm yayını: `@lepton-desk/*`

Şu anki sürüm: **0.1.8** (0.1.0–0.1.7 yayımlandı; `create-lepton-app` 0.1.4 ile çıktı). Sürüm artırımı tek komut: `node tools/release-version.mjs <sürüm>`. `Cargo.toml` (CLI sürümünü
derlemede buradan okur: `--version`, komut başlıkları, yeni projelerin `@lepton-desk/*` sürümleri),
`Cargo.lock`, sekiz npm paketinin `version`'ı, `cli`'nin `optionalDependencies`'i, eklentilerin
`^<sürüm>` `peerDependencies`'i, `create-lepton-app`'in `@lepton-desk/cli`'si, `lepton update`'in
şablon geçmişi (`assets/history/<sürüm>/` + `RELEASES`), AUR `pkgver`'i ve bu dosyanın sürümü.
Yayından sonra `node tools/release-version.mjs aur`: `-bin`'in sha512'si npm'den, kaynak paketin
commit'i HEAD'den, `.SRCINFO`'lar yeniden. Platform paketini `stage.mjs` yazar.

Yayımlanacaklar, bu sırayla: `@lepton-desk/cli-linux-x64` → `@lepton-desk/cli` →
`@lepton-desk/api` → eklentiler (`plugin-os`, `plugin-clipboard`, `plugin-fs`, `plugin-dialog`; `api`'ye eş bağımlı) → `create-lepton-app` (en son; `@lepton-desk/cli`'nin aynı sürümüne bağlı). Platform paketi önce gider; `cli` ona `optionalDependencies` ile bağlı.

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

```bash
cd packages/cli-linux-x64 && npm publish
```

```bash
cd packages/cli && npm publish
```

```bash
cd packages/api && npm publish
```

```bash
cd packages/plugin-os && npm publish
```

```bash
cd packages/plugin-clipboard && npm publish
```

```bash
cd packages/plugin-fs && npm publish
```

```bash
cd packages/plugin-dialog && npm publish
```

```bash
cd packages/create-lepton-app && npm publish
```

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
