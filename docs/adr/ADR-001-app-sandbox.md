# ADR-001: App Sandbox и способ дистрибуции

- **Статус:** открыто (решается после спайков этапа 0, см. TZ.md §7, риск R1)
- **Дата:** 2026-10-14

## Контекст

Глобальный перехват клавиатуры через `CGEventTap` и чтение текста через
Accessibility API, скорее всего, несовместимы с App Sandbox. Без sandbox
публикация в Mac App Store невозможна — остаётся дистрибуция напрямую
(dmg + Developer ID + notarization).

## Варианты

1. **Sandbox + исключения** — попробовать `com.apple.security.temporary-exception`
   для event tap. Позволяет Mac App Store.
2. **Без sandbox, дистрибуция вне MAS** — как Rectangle, Keyboop, SwitchFix.
   Обязательны: Developer ID, notarization, Hardened Runtime, Sparkle EdDSA.

## Критерии решения

Результаты спайков P0.1–P0.3 (TZ.md §5): если event tap и AX-конвертация
работают из-под sandbox без temporary exceptions — вариант 1, иначе вариант 2.

## Решение

_(будет заполнено после этапа 0)_
