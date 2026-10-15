# npm yayını: `@lepton-desk/*`

Şu anki sürüm: **0.1.2** (0.1.0 ve 0.1.1 yayımlandı; eklentiler ilk kez 0.1.2 ile çıkar). Sürüm artırımı: `Cargo.toml`
`[workspace.package] version`, `packages/api`, `packages/cli` ve `packages/plugin-*`
`package.json` (cli'nin `optionalDependencies`'i ve eklentilerin `peerDependencies`'i dahil);
platform paketini `stage.mjs` yazar.

Yayımlanacaklar, bu sırayla: `@lepton-desk/cli-linux-x64` → `@lepton-desk/cli` →
`@lepton-desk/api` → eklentiler (`plugin-os`, `plugin-clipboard`, `plugin-fs`, `plugin-dialog`; `api`'ye eş bağımlı). Platform paketi önce gider; `cli` ona `optionalDependencies` ile bağlı.

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

`publishConfig.access: public` her pakette var; `--access public` gerekmez.
`api` yayından önce kendi `prepublishOnly`'sini çalıştırır (derleme + denetim + test).

## 5. Doğrulama (boş bir dizinde)

```bash
npm view @lepton-desk/cli version
```

```bash
npx @lepton-desk/cli@0.1.2 --version
```

Beklenen: `lepton 0.1.2`.

## 6. Geri alma
- 72 saat içinde: `npm unpublish @lepton-desk/<paket>@<sürüm>` (aynı sürüm bir daha kullanılamaz).
- Sonrası: `npm deprecate @lepton-desk/<paket>@<sürüm> "<neden>"`.

## Yayından sonra (benim işim)
- Yeni sürüm kayıt defterinde görünür olunca (ilk yayında ~5 dk sürdü) `npx` ve yeni bir
  proje `pnpm install` + `lepton run` ile doğrulanır.
- Diğer platformlar: kendi makinelerinde/CI'da `cargo build --release` + `stage.mjs`, sonra
  `cli`'nin `optionalDependencies`'ine eklenip `cli` yeni sürümle yeniden yayımlanır.
