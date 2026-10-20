## Why

Пользователю нужен заполненный GitHub About и скачиваемый дистрибутив LSwitch.
Полная приёмка и Developer ID/notarization ещё отсутствуют, поэтому выпуск экспериментальный.

## What Changes

- Описание, homepage релизов и topics репозитория.
- Повторяемая Universal Release-сборка macOS 13+ (arm64/x86_64), ZIP/DMG/SHA256.
- GitHub prerelease v0.1.0-alpha.1 с точным commit, инструкцией и известными ограничениями.
- Публичная ad-hoc подпись; отсутствие Developer ID/notarization явно указано.

## Capabilities

### New Capabilities

- `release-distribution`: скачиваемая предварительная поставка и проверки её состава.

### Modified Capabilities

Нет.

## Impact

Makefile, packaging script, документация, GitHub metadata и release assets.
Рабочая локальная сборка и разрешения пользователя не заменяются. Незавершённые
stage0/1/2 и fix-input-recovery не объявляются принятыми.
