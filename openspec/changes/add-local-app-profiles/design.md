## Context

AppProfiles содержит встроенные правила, Converter кеширует обнаруженный маршрут,
clipboard transport и selection отдельно читают политики. Изменить только первый
bool недостаточно: все слои должны получить один локальный профиль и его revision.

## Goals / Non-Goals

Goals: точные локальные overrides, безопасный однозначный routing и понятный UI.
Non-Goals: загрузка удалённых правил, скрипты в профилях, обход guard/права/VS Code,
включение DEBUG Unicode либо незавершённого recovery runtime.

## Decisions

- Observable LocalAppProfiles с versioned JSON в UserDefaults, валидируемыми bundle ID
  и enum-режимами. Встроенный режим представлен отсутствием записи.
- Один экземпляр инъецируется в Converter и live clipboard environment; тесты используют
  отдельные defaults. Никакого глобального изменения тестов через реальные preferences.
- Revision захватывается с context check; изменение делает старый request невалидным.
  На следующем trigger очищаются modeCache и undo. Применённый transport не меняется
  на лету после await. Tracked routing также соблюдает профиль и admission Session.
- Known-unsafe AX и AppRules имеют приоритет. Явный AX для них блокируется до engine;
  clipboard guard VS Code не изменяется. UI объясняет ограничения.
- NSOpenPanel выбирает .app и читает только bundle metadata. Также доступен ручной ID.
  Редактирование выполняется явным сохранением; удаление профиля возвращает builtin.

## Risks / Trade-offs

- Не каждый редактор поддерживает выбранный метод → отказ без ослабления guard,
  встроенный профиль всегда доступен для сброса.
- Clipboard-путь может быть медленнее → пользователь явно выбирает совместимость;
  общие пределы lease/таймаутов не увеличиваются.
- Режимы локальны; содержимое документов и clipboard в профиле не сохраняется.
