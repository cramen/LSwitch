# AGENTS.md

Гайд для AI-агентов, работающих с этим репозиторием.

## Команды

- Сборка/тесты: `make build`, `make test` (НЕ голый `swift build`/`swift test` —
  xcode-select указывает на CLT без XCTest; Makefile выставляет DEVELOPER_DIR
  на полный Xcode).
- Запуск приложения: `make run-app` (`.build/LSwitch.app`, подпись
  сертификатом «LSwitch Dev» из login keychain — разрешения TCC переживают
  пересборку; рецепт регенерации сертификата: `docs/dev-setup.md`).
- Линт: SwiftLint `--strict` только в CI (локально не установлен). Перед
  пушем проверяй: строки ≤ 120 символов (в unicode-символах, не байтах),
  без trailing comma в литералах, идентификаторы ≥ 3 символов,
  `@testable import` перед `import XCTest`, без force unwrap (`!`).
- Диагностика на машине: `lswitch --probe`; логи:
  `log show --last 10m --info --predicate 'subsystem == "LSwitch"'`.

## Workflow

- Изменения ведутся через OpenSpec: артефакты в `openspec/changes/<name>/`
  (proposal → specs → design → tasks), скиллы `openspec-*`. Перед кодом —
  артефакты; задачи отмечаются `[x]` только при полном выполнении проверки.
- Коммиты на русском, одна строка-заголовок + тело со смыслом; push в main,
  CI должен быть зелёным (build + test + lint).

## Конвенции кода

- Swift, macOS 13+, комментарии и документация — на русском.
- Чистая логика (классификаторы, детекторы, границы слов) отделена от
  системных вызовов и покрывается unit-тестами; системные вызовы собраны
  за протоколами/замыканиями для подмены в тестах.
- TIS API и NSWorkspace — только главный поток (крэш иначе);
  AX-позиции в UTF-16; подробности — `docs/macos-quirks.md`.

## Документация

- `TZ.md` — ТЗ и план релизов; `docs/adr/` — архитектурные решения;
- `docs/dev-setup.md` — окружение разработки; `docs/macos-quirks.md` —
  проверенные особенности macOS API; `NOTICE.md` — атрибуция словарей.
