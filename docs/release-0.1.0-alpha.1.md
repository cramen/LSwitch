# Публикация v0.1.0-alpha.1 — 20.10.2026

Релиз: https://github.com/cramen/LSwitch/releases/tag/v0.1.0-alpha.1
Статус: опубликованный prerelease, не Latest stable.
Tag commit: `8890a496d382fecd62a950a0a5a14cb014e0979b`.
CI: https://github.com/cramen/LSwitch/actions/runs/39432318197 — все шаги зелёные.

## Репозиторий

Заполнены description, homepage на /releases и 10 topics: macos, swift,
keyboard-layout, keyboard-switcher, russian, english, productivity, menu-bar,
accessibility, punto-switcher. Значения подтверждены GitHub API.

## Поставка и проверка

- `make release-dist RELEASE_VERSION=0.1.0-alpha.1` из чистого checkout.
- Release arm64/x86_64, обе LC_BUILD_VERSION имеют minos 13.0.
- Universal executable SHA256: `4c0830bc83f43c1ef5e5edd01065e75bc749a322abf821e81bc2bb74c21920a1`.
- CFBundleShortVersionString=0.1.0, CFBundleVersion=1; prerelease/version/source
  также записаны в Info.plist и build-info.json.
- Техническая ad-hoc подпись с runtime flag; codesign --verify --deep --strict
  успешен для ZIP и DMG. Developer ID и notarization отсутствуют.
- `--verify-resources` из распакованного ZIP и read-only mounted DMG: dictionaries ok,
  путь ресурсов принадлежит соответствующему извлечённому .app, не checkout.
- Release отвергает `--recovery-isolation-control` с кодом 2 до запуска AppDelegate.
- LICENSE/NOTICE.md включены снаружи и внутрь .app; README.txt с ограничениями рядом.
- DMG checksum verification успешен, Applications symlink указывает на /Applications.
  Образ отключён после проверки.
- Все 4 assets загружены; GitHub digest совпал с локальным. После публикации assets
  скачаны обратно, SHA256SUMS подтверждены; ZIP отдельно скачан без авторизации
  по публичному URL и имеет тот же hash. Tag через API указывает на source commit.

| Файл | SHA256 |
|---|---|
| LSwitch-0.1.0-alpha.1-macOS-universal.dmg | bfd49fc8911a5c44e80facafa1710d5f9834c1c2dc513f28c087dce2272fef17 |
| LSwitch-0.1.0-alpha.1-macOS-universal.zip | b93688676a2098533bf9350c358c30cce33a829d00212686336b7d66db4685cb |
| build-info.json | 07c96746f9b92ac5810ae444887276c4239068c2458e8c2684c3db92efbb09e9 |

## Границы

Это alpha с известным открытым риском recovery; предупреждение находится в первых
абзацах release notes, README репозитория и README.txt поставки. Stable acceptance,
Developer ID/notarization, физический Intel и полная редакторная матрица не приняты.
На этой машине проверен native arm64 CLI ресурса; полноценный GUI-сеанс публичной
ad-hoc сборки и выдача новых TCC-прав не выполнялись. Локальная dev-сборка пользователя
и её разрешения не заменялись. Stage0/1/2 и fix-input-recovery остаются открытыми.
