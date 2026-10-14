# Статический анализ Caramba Switcher Pro

Дата: 2026-10-14. Цель — проверить технические подходы установленного аналога
и оценить их применимость к исправлению LSwitch.

## Границы исследования

Выполнены только чтение метаданных приложения, просмотр списка ресурсов,
импортируемых API и отдельных имён/диагностических строк бинарника.
Приложение не запускалось; его UI, настройки, лицензия и бинарник не изменялись.
Закрытый код, словари и правила Caramba не копировались в LSwitch.
Декомпиляция алгоритмов и динамическая трассировка не выполнялись.

Этот отчёт различает наблюдаемые признаки и гипотезы. Наличие импорта не доказывает,
что API используется в каждом преобразовании; отсутствие прямого импорта
не исключает динамический вызов.

## Подтверждённые сведения

Объект: `/Applications/Caramba Switcher Pro.app`.

- Версия `2026.10.07`, сборка `20261007.1`, bundle ID `tech.caramba.switcher`.
- Основной файл — universal Mach-O для `arm64` и `x86_64`.
- Минимальная версия macOS — 12.0; `LSUIElement=1`.
- В подписи указаны TeamIdentifier `AKZHD7272L` и hardened runtime.
- Локальная проверка подписи вернула `CSSMERR_TP_NOT_TRUSTED`, а извлечение
  entitlements — предупреждение об invalid blob. Причина не исследовалась;
  это не вывод о происхождении или безопасности приложения.
- В bundle есть основной executable, `CarambaSwitcherUI.framework`, login helper,
  локализации, assets и модели CoreData.
- Диагностические пути содержат имена модулей Swift и Rust, включая classifier,
  replacement, dictionary и macOS transport. Исходники по этим путям не читались.

В таблице импортов основного `arm64` executable найдены:

| Область | API или системные уведомления |
| --- | --- |
| Перехват | `CGEventTapCreate`, `CGEventTapEnable` |
| Генерация ввода | `CGEventCreateKeyboardEvent`, `CGEventPost`, `CGEventPostToPid` |
| Раскладки | `TISCopyCurrentKeyboardInputSource`, `TISSelectInputSource`, `UCKeyTranslate`, `LMGetKbdType` |
| Защищённый ввод | `IsSecureEventInputEnabled`, `AXIsProcessTrustedWithOptions` |
| Буфер обмена | `NSPasteboard`, `NSPasteboardItem`, `NSPasteboardTypeString` |
| Хоткеи | `RegisterEventHotKey`, `UnregisterEventHotKey`, `CopySymbolicHotKeys` |
| Жизненный цикл | `NSWorkspaceDidActivateApplicationNotification`, `NSWorkspaceDidWakeNotification` |
| Начало пользовательской сессии | `NSWorkspaceSessionDidBecomeActiveNotification` |
| Конец пользовательской сессии | `NSWorkspaceSessionDidResignActiveNotification` |

Прямых импортов `AXUIElement*` и `AXObserver*` в основном executable и UI framework
не найдено. Единственный относящийся к AX импорт основного executable —
`AXIsProcessTrustedWithOptions`.

В строках бинарника найдены имена:

- `delay_between_layout_activation_and_backspaces`;
- `delay_between_backspaces_and_retyping`;
- `layout_switch_num_retries`, `layout_switch_retry_delay`;
- `special_behaviors`, `AppexRuleSet`, `AppExceptionsStore`, `AutoswitchExceptionsStore`;
- `secureInputEnabled`, `secureInputAlertTimer`;
- отдельный `PasteWithoutFormattingModule`.

Локализация содержит уведомление о блокировке Caramba защищённым вводом.
Подтверждений алгоритма восстановления позиции ввода или точного отката
получить не удалось.

## Гипотезы и ограничения выводов

Названия параметров задержек согласуются с путём «активация раскладки → Backspace →
повторный ввод». Возможно, его поведение настраивается для отдельных приложений.
Сочетание `CGEventPostToPid` и параметров повторного ввода также согласуется
с адресной отправкой событий процессу. Однако назначение конкретных вызовов,
порядок шагов, точные задержки и критерии выбора пути не восстановлены.

Наличие pasteboard API само по себе не доказывает, что каждое преобразование
использует clipboard: в приложении есть отдельная функция вставки без форматирования.
Отсутствие прямых AX-импортов также не позволяет утверждать, что AX не используется вовсе.

## Применение к решениям LSwitch

1. **Secure Input.** Системная проверка защищённого ввода дополняет проверку
   парольного AX-поля. В нашем D4 такой отказ прекращает накопление ввода
   и все движки до выделения/копирования, без clipboard fallback.
2. **Явные задержки.** В D3 паузы между этапами clipboard-операции остаются
   параметрами адаптера. Их значения и достаточность определяются нашими
   проверками TextEdit, Safari и Electron, а не угадываются по чужому бинарнику.
   Пауза не заменяет проверку актуальности фокуса и результата операции.
3. **Профили приложений.** Сохраняется выбор рабочего движка для известных
   приложений и возможность отдельно настраивать проверенные особенности.
   Правила Caramba не извлекались и не переносились.
4. **Backspace и повторный ввод.** Это отдельный вариант для будущего эксперимента.
   Ему нужны собственные проверки доставки событий, позиции, смены фокуса,
   пользовательского ввода и возможности отката. Текущие AX/clipboard-пути
   не заменяются без этих доказательств. Исправления выполняются по D1–D4.
5. **Точный откат.** Хранение исходного текста в LSwitch следует из наших
   воспроизведений необратимой пунктуации. Внутренний способ undo Caramba неизвестен.

## Воспроизведение чтения

Команды ничего не изменяют в исследуемом приложении:

```sh
app='/Applications/Caramba Switcher Pro.app'
binary="$app/Contents/MacOS/Caramba Switcher Pro"
ui="$app/Contents/Frameworks/CarambaSwitcherUI.framework/Versions/A/CarambaSwitcherUI"
plutil -p "$app/Contents/Info.plist"
file "$binary"
codesign -dv --verbose=4 "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements :- "$app"
rg --files "$app/Contents"
otool -L "$binary"
otool -l "$binary"
nm -arch arm64 -u "$binary" | rg 'CGEvent|AXUI|AXIs|AXObserver|TIS|UCKey|Secure|Pasteboard|NSWorkspace|HotKey'
nm -arch arm64 -u "$ui" | rg 'AXUI|AXObserver|CGEvent|Pasteboard|TIS|Secure|NSWorkspace'
strings -a "$binary" | rg 'backspaces|retyping|layout_switch|special_behaviors|secureInput|ExceptionsStore'
```

Результат исследования — архитектурные ориентиры и проверяемые гипотезы,
а не подтверждение работоспособности Caramba или совместимости LSwitch.
