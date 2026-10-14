## Context

См. proposal.md. Из stage0-spikes уже есть и проверено: `EventTapCore`
(перехват + метка синтетики + recovery), `KeystrokeBuffer`, `LayoutMap`,
`AXTextConverter` (работает в TextEdit), `ClipboardConverter` (работает,
с паузами фокуса/вставки), `PasteboardSnapshot`. ADR-001: без sandbox.
Спеки: `hotkey-conversion`, `layout-management`, `app-rules`,
`permissions-guard`, `settings`.

## Goals / Non-Goals

**Goals:**

- Ручная конвертация по двойному Shift end-to-end: детект → конвертация
  (AX-first, clipboard-fallback) → переключение раскладки → откат.
- Продуктовый каркас: blacklist, PermGuard, настройки, автозапуск.

**Non-Goals:**

- Автопереключение и классификатор (этап 2).
- Конвертация произвольного выделения и смена регистра (F14, этап 3).
- Конфигурируемые хоткеи: в MVP хоткей фиксирован (двойной Shift),
  настройка — этап 3 (F13/F6 расширенные).
- Notarization/подпись релиза — отдельная задача релиза 0.1.

## Decisions

### D1. Детект двойного Shift — чистый конечный автомат

`DoubleShiftDetector` получает `RawKeyEvent` и возвращает `.triggered` при
двух keyDown Shift подряд (интервал ≤ 500 мс, между ними нет других
клавиш). Чистая логика без системных вызовов — полностью покрывается
unit-тестами. Альтернатива (сравнение timestamp внутри EventTapCore)
отклонена: смешивает транспорт и логику.

Нюанс: Shift приходит как `flagsChanged`, а не keyDown; keyCode 56 (левый)
и 60 (правый) считаются равнозначными. Нажатие Shift с зажатой другой
клавишей (Shift+A) сбрасывает автомат.

### D2. Откат — обратная конвертация, а не снапшот позиций

`LayoutMap.invert` симметричен: invert(invert(x)) == x. Поэтому откат =
повторная конвертация того же слова + переключение раскладки обратно.
`UndoStore` хранит: слово до, слово после, раскладку до, timestamp.
Валиден, только если ни одного другого keystroke и окно (3 с) не истекло.
Компромисс: если пользователь отредактировал слово после конвертации,
откат применится к отредактированному варианту — принято для MVP
(в этапе 3 с F14 можно перейти на снапшоты выделения).

### D3. LayoutManager — TIS по ID источника

`TISCopyCurrentKeyboardLayoutInputSource` → `kTISPropertyInputSourceID`;
соответствие: id содержит "Russian" → ru, "ABC"/"U.S." → en, иначе nil
(неизвестная → конвертация не выполняется, spec layout-management).
Переключение: `TISCopyInputSourceList` + `TISSelectInputSource` для
целевого id. Список кандидатов логируется при старте для диагностики
на машинах с нестандартными раскладками (RU-PC и т.п.).

### D4. Оркестрация конвертации в `Converter`

`Converter.convertLastWord()`: проверяет blacklist (AppRules) → выбирает
режим из кэша (in-memory [bundleID: Mode]) → AX, при ошибке — clipboard →
успех: пишет UndoStore, переключает раскладку через LayoutManager, звук
(если включён). Повторный триггер в окне → `undo()`.
Кэш намеренно не персистентен в MVP (per-app профили — этап 3).

### D5. PermGuard — периодический опрос

Таймер 5 с: `AXIsProcessTrusted()` + `CGPreflightListenEventAccess()`.
Потеря → стоп EventTapCore + NSUserNotification-замена (alert при открытии
меню + пункт со статусом). Восстановление → рестарт tap. Пуш-уведомления
(UNUserNotificationCenter) откладываем до этапа 3 (нужен bundle id и
подпись для стабильной работы) — MVP показывает статус в меню и alert.

### D6. Настройки — SettingsStore поверх UserDefaults

`SettingsStore: ObservableObject` с @Published свойствами (enabled,
undoWindowSeconds, soundEnabled, blacklist, launchAtLogin). SwiftUI-окно
настроек открывается из меню (`NSWindow` + `NSHostingView`, LSUIElement —
активируем приложение принудительно при показе). Автозапуск:
`SMAppService.mainApp.register()/unregister()`; в debug-бандле без
подписи может быть недоступен — ошибка показывается в настройках,
не роняет приложение.

## Risks / Trade-offs

- [Двойной Shift конфликтует с Caps Lock-привычками и языковыми переключателями пользователя] → хоткей станет настраиваемым в этапе 3; в MVP детект требует «чистого» двойного нажатия без других клавиш.
- [Откат через обратную конвертацию некорректен после ручного редактирования слова] → окно 3 с + сброс на любой keystroke; принято для MVP.
- [TISSelectInputSource иногда не переключает в чужих приложениях мгновенно] → известное поведение macOS; переключение проверяется чтением после 100 мс, при неуспехе — повтор.
- [SMAppService в ad-hoc debug-бандле может отказать] → ошибка отображается пользователю, настройка откатывается; для релиза нужна Developer ID-подпись (ADR-001).

## Open Questions

- Точные TIS ID раскладок на машине пользователя (RU vs RU-PC) — выяснится
  при первом запуске, логирование заложено; соответствие по подстроке
  покрывает оба.
