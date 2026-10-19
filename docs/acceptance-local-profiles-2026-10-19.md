# Локальные профили — 19.10.2026

Change: `add-local-app-profiles`. Четыре режима по точному bundle ID, versioned JSON
в UserDefaults, выбор .app или ручной ID, редактирование/сброс без перезапуска.
Профили не включают recovery runtime и не отменяют встроенные запреты.

## Model / build

1158 тестов без failures/skips. Новые проверки: persistence/точные ID/reset,
повреждённые/будущие/неизвестные записи, AX-only без fallback, disabled до hold,
сброс cached route и undo, profile revision ABA внутри операции, unsafe AX/терминалы,
tracked routing с сохранением admission Session. Сборки Debug/Release и 27 protocol
checks проходят. Логи `.build/local-profiles-{build,test,release,protocol}.log`.

## Live v1

- Через NSOpenPanel выбран `/System/Applications/TextEdit.app`; UI получил
  `com.apple.TextEdit`. Без перезапуска сохранён keyboard+clipboard профиль.
- Две конвертации clipboard прошли (373/362 мс), два отката дали holdExpired
  (471/455 мс). AX-исходник ghbdtn восстановился, но это НЕ успешный undo.
  Лимит не менялся. Этот результат записан как ограничение принудительного
  clipboard в TextEdit; пользователь может вернуться к подходящему режиму.
- Смена на AX-only: converted/undone, 159/192 мс, точный ghbdtn по AX.
- Disabled: хоткей оставил ghbdtn неизменным, новая конвертация не запускалась.
- После перезапуска UI сохранил Disabled для TextEdit. Сброс удалил override;
  встроенный маршрут дал converted/undone (161/191 мс), точный исходник по AX.
- Clipboard-аудитор: matches=true, 1 item/4 types, changeCount 3316→3324.
  Содержимое не выводилось и не записывалось на диск. Аудитор завершён.
- Тестовые overrides удалены. Пользовательский Option+Space и auto OFF/sound ON
  сохранены. Логи `.build/local-profiles-live.log`, driver logs с тем же префиксом.

Ввод выполнялся только в собственном recovery-pilot-textedit-20261017.txt ранее
разрешённым драйвером. Не заявляется совместимость каждого режима с любым редактором.
Финальная версия дополнительно связывает clipboard context с revision профилей
и убирает устаревшее сообщение «сохранён» после редактирования режима.

## Финальная установка

CI `fec0cf7` зелёный: https://github.com/cramen/LSwitch/actions/runs/39244185608 .
Первый CI нашёл только large_tuple в тестовой фикстуре; он заменён структурой.
Build, Release, 1158 tests, 27 protocol groups и strict SwiftLint прошли.
OpenSpec strict: 9/9. Все четыре задачи change выполнены.

Финальная сборка установлена в `.build/LSwitch.app`, SHA256
`811281649da871dd362473ca3fc71fbb8810a55ec342068b32c10a4c5493329a`.
Проверен новый раздел UI, пустой список overrides и сохранённый Option+Space.
Предыдущая сборка: `.build/LSwitch-before-local-profiles-20261019.app`.
