# Окружение разработки LSwitch

Практические детали машины разработки и сборки, собранные опытным путём
(этапы 0–2). Уроки по API macOS — отдельно в `docs/macos-quirks.md`.

## Xcode и тулчейн

- На машине `xcode-select` указывает на Command Line Tools, где **нет XCTest**
  (`swift test` падает с «XCTest not available»). Поэтому `Makefile` экспортирует
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` — используй
  `make build` / `make test`, а не голый `swift build`/`swift test`.
- Голый `swift test` в шелле заработает после
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
  (не сделано на момент написания — требует пароля).
- SwiftLint локально **не установлен** (`brew install` отваливался по таймауту);
  источник истины — CI (GitHub Actions, шаг SwiftLint `--strict`). Перед пушем
  проверяй типовые нарушения: длина строки ≤ 120, без trailing comma,
  идентификаторы ≥ 3 символов, `@testable import` перед `import XCTest`.

## Dev-подпись и TCC (критично для отладки)

Приложение требует разрешений Accessibility и Input Monitoring, а macOS
привязывает разрешения к подписи кода. Поэтому dev-сборка подписывается
**self-signed сертификатом «LSwitch Dev»** (в login keychain) — разрешения
переживают пересборку. С ad-hoc подписью (cdhash) они слетают при каждой
пересборке.

`make app` собирает `.build/LSwitch.app` и подписывает этим сертификатом;
`make run-app` — запускает. Разрешения выдаются один раз.

### Регенерация сертификата «LSwitch Dev» (если потерян)

Два других варианта параметров не работают: сертификат без `keyUsage`
не считается валидным для codesigning, а с `CA:true` + critical EKU —
«Invalid Key Usage for policy». Рабочий рецепт:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=LSwitch Dev/" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout /tmp/lswitch-dev.key -out /tmp/lswitch-dev.crt -days 3650
openssl pkcs12 -export -legacy -name "LSwitch Dev" \
  -inkey /tmp/lswitch-dev.key -in /tmp/lswitch-dev.crt \
  -out /tmp/lswitch-dev.p12 -passout pass:<пароль>
security import /tmp/lswitch-dev.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "<пароль>" -A
security add-trusted-cert -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/lswitch-dev.crt
security find-identity -v -p codesigning   # должна быть строка "LSwitch Dev"
```

Нюансы: `-legacy` у pkcs12 обязателен (иначе `MAC verification failed`),
импорт key и crt по отдельности identity **не образует** — только через .p12.

### Сброс разрешений при отладке

```bash
tccutil reset Accessibility ru.cramen.lswitch
tccutil reset ListenEvent ru.cramen.lswitch
```

После сброса перезапусти приложение — диалоги разрешений появятся заново.
Диалоги показываются только для `.app`-бандла, запущенного через `open`
(из терминала голый бинарник наследует TCC-контекст терминала).

## Диагностика

- `lswitch --probe` (или `.build/LSwitch.app/Contents/MacOS/LSwitch --probe`):
  sandbox-статус, разрешения TCC, создание/доставка event tap, AX-доступ,
  список TIS-источников, круговое переключение раскладки.
- Логи: `log show --last 10m --info --predicate 'subsystem == "LSwitch"'`
  (info-уровень не персистентен — флаг `--info` обязателен).
- `.build/LSwitch.app/Contents/MacOS/LSwitch --verify-resources` проверяет словари
  и печатает путь ресурсного bundle без запуска перехвата. Эта же команда должна
  работать после переноса `.app` в другой каталог. Внутри `.app` поиск ресурсов
  не использует абсолютный путь SwiftPM из каталога сборки.
- Повторное открытие запущенного `.app` показывает окно настроек.

## CI

GitHub Actions (`.github/workflows/ci.yml`), раннер `macos-14`: явный
`xcode-select` на полный Xcode (по умолчанию на раннерах CLT без XCTest),
затем build → test → SwiftLint.

## Релизная перспектива

Для релиза нужен Apple Developer ID (сертификата на машине нет) +
notarization + dmg. Решение о дистрибуции вне Mac App Store — ADR-001.

## Предварительный дистрибутив

Из чистого закоммиченного checkout: `make release-dist RELEASE_VERSION=0.1.0-alpha.1`.
Результат: `dist/0.1.0-alpha.1/` (Universal ZIP/DMG, SHA256SUMS.txt и build-info.json).
Повторная сборка требует нового RELEASE_DIR, чтобы не перезаписывать готовый кандидат.
Рецепт собирает Release arm64/x86_64 отдельно и объединяет lipo; ресурсы сравниваются.
Рабочая `.build/LSwitch.app` не изменяется. В alpha используется ad-hoc подпись,
не локальный сертификат LSwitch Dev. Это не замена Developer ID/notarization
для стабильного выпуска. Отсутствие notarization и открытый риск recovery
обязательно указываются в release notes и README поставки.
