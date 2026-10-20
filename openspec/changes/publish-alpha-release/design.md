## Context

Существующий make app создаёт Debug с локальной dev-подписью. Для скачивания нужен
отдельный build output; текущий рабочий .app нельзя переписывать.

## Goals / Non-Goals

Goals: повторяемая alpha-поставка и проверенные GitHub assets.
Non-Goals: stable release, новая signing identity, notarization без Developer ID,
подмена product acceptance или включение DEBUG Unicode/recovery.

## Decisions

- Отдельная Makefile-цель и packaging script, Release для двух архитектур,
  lipo и ad-hoc подпись. Версия 0.1.0, alpha.1 в имени GitHub/tag/README поставки.
- Упаковка в отдельный dist-путь, лицензии и инструкция рядом с .app.
- Проверка ресурса --verify-resources из извлечённого ZIP и проверка обеих
  архитектур/header deployment target; native запуск только arm64.
- Публикация на точный commit после CI. Assets повторно скачиваются и сверяются.

## Risks / Trade-offs

- Gatekeeper может блокировать ненотаризованную поставку → честное обозначение alpha,
  официальная инструкция macOS, без автоматического снятия quarantine.
- Intel на этой машине не проверяется аппаратно → различать cross-build и hardware acceptance.
- Известный P1 recovery → заметное предупреждение, не stable/latest release.
