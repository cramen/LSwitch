## Context

Живой журнал `com.openai.codex` фиксирует AX text-write-not-confirmed, затем
подтверждённую исходную каретку. Общая реакция на failed запрещает переход к другой
мутации; поэтому выбирать clipboard нужно до AX-попытки, как для Chrome.

## Goals / Non-Goals

Goals: точный профиль Codex, native selection/Copy/Paste и прежняя проверка результата.
Non-Goals: fallback после failed AX, ослабление snapshot/identity/clipboard guards,
принятие отдельного ChatGPT или общего recovery runtime.

## Decisions

- Точный bundle ID `com.openai.codex` включается в clipboard preference и native
  command/selection policies. Прямой AX setter текста не используется.
- ClipboardTransaction остаётся прежним: свежие full text/range проверки,
  независимый clipboard ownership и точный undo обязательны.
- Регрессии проверяют routing до первой мутации и отсутствие AX-запроса.
- CUA запрещает доступ к Codex. Живая проверка выполняется пользователем в пустом
  тестовом черновике без отправки; журналы показывают только метаданные исходов.

## Risks / Trade-offs

- AX-модель поля может не совпадать с DOM → сохраняем отказ, не выдаём отсутствие
  ошибки за успешную вставку; принимаем профиль только после живого результата.
- Clipboard временно используется → прежнее содержимое восстанавливается только
  при своём changeCount; более новое копирование не перезаписывается.
