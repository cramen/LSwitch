# ADR-001: App Sandbox и способ дистрибуции

- **Статус:** принято
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

## Эксперимент (спайк P0.4, задача 5.1 change stage0-spikes)

Один и тот же бинарник (`lswitch --probe`) собран и запущен в двух вариантах:
без подписи и с ad-hoc подписью + entitlement `com.apple.security.app-sandbox`
(с встроенным Info.plist — sandbox-бинарник без CFBundleIdentifier падает
в `libsystem_secinit` на старте).

| Проверка | Обычная сборка | Sandbox-сборка |
|---|---|---|
| Sandbox активен | нет | **да** (entitlement применён) |
| `AXIsProcessTrusted` | false | false |
| AX чтение focused element | ошибка -25211 | **ошибка -25204 (kAXErrorAPIDisabled)** |
| `tapCreate` (listenOnly) | создан | создан |
| Доставка событий в tap | молчит без разрешения | молчит без разрешения |

Дополнительные факты:

- Accessibility-разрешение архитектурно недоступно sandbox-приложениям:
  entitlement для него не существует, а AX-режим конвертации — обязательный
  приоритетный путь по спецификации (`specs/text-conversion`), clipboard —
  лишь fallback. Даже если бы event tap удалось поднять через temporary
  exceptions, без AX продукт теряет ключевое преимущество (конвертация без
  затирания буфера обмена).
- Все работающие приложения этого класса (Rectangle, Karabiner-Elements,
  BetterTouchTool, SwitchFix) распространяются без sandbox: Developer ID +
  notarization.
- `CGPreflightListenEventAccess` при запуске из терминала возвращает `true`
  из-за наследования контекста TCC родителя — для реальных проверок нужна
  стабильная подпись бинарника, иначе разрешения сбрасываются при пересборке.
- На машине разработки нет ни одного codesigning-сертификата — для релиза
  потребуется Developer ID (учётная запись Apple Developer).

## Решение

**Вариант 2: без App Sandbox, дистрибуция вне Mac App Store.**

- Подпись Developer ID Application + notarization + Hardened Runtime
  с минимумом entitlements (см. TZ.md §3.3).
- Автообновления (с релиза 0.3) — Sparkle 2 с EdDSA-подписью.
- Mac App Store исключается из каналов дистрибуции: требования продукта
  (глобальный event tap + Accessibility) несовместимы с sandbox.
