# npm yayını: `@lepton-desk/*` 0.1.0

Yayımlanacaklar, bu sırayla: `@lepton-desk/cli-linux-x64` → `@lepton-desk/cli` →
`@lepton-desk/api`. Platform paketi önce gider; `cli` ona `optionalDependencies` ile bağlı.

## 1. Sizin kararınız gerekenler (ön kontrol bunlarsız geçmez)
- ~~Lisans metinleri~~ — eklendi: `LICENSE-MIT` (2026 Lepton Desk Contributors) ve
  `LICENSE-APACHE` (apache.org'dan). Ön kontrol bunları üç pakete kopyalar.
- ~~Depo adresi~~ — `https://github.com/lepton-desk/lepton` oluşturuldu (herkese açık, `main`).

## 2. Ön kontrol (hiçbir şey yayımlamaz)

```bash
tools/npm-preflight.sh
```

Sürüm eşitliği, npm'de o sürümün boş olması, lisanslar, Rust test/clippy, ikilinin
`cli-linux-x64`'e konması, `@lepton-desk/api` derleme/denetim/test, `cli` testleri ve her
tarball'ın içeriği. Sonu `preflight: ready to publish 0.1.0` olmalı.

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

`publishConfig.access: public` her pakette var; `--access public` gerekmez.
`api` yayından önce kendi `prepublishOnly`'sini çalıştırır (derleme + denetim + test).

## 5. Doğrulama (boş bir dizinde)

```bash
npm view @lepton-desk/cli version
```

```bash
npx @lepton-desk/cli@0.1.0 --version
```

Beklenen: `lepton 0.1.0`.

## 6. Geri alma
- 72 saat içinde: `npm unpublish @lepton-desk/<paket>@0.1.0` (aynı sürüm bir daha kullanılamaz).
- Sonrası: `npm deprecate @lepton-desk/<paket>@0.1.0 "<neden>"`.

## Yayından sonra (benim işim)
- Şablonlar yerel `src/lepton.ts` yerine `@lepton-desk/api`'ye bağlanır; `lepton new` ile
  yeni proje `pnpm install` + `lepton run` ile doğrulanır.
- Diğer platformlar: kendi makinelerinde/CI'da `cargo build --release` + `stage.mjs`, sonra
  `cli`'nin `optionalDependencies`'ine eklenip `cli` yeni sürümle yeniden yayımlanır.
