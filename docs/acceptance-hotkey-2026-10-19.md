# Настраиваемый хоткей — 19.10.2026

Change: `configure-conversion-hotkey`. Сохранены default double Shift и общий путь
conversion/undo, прежние guards исключений и InputSafety. Новый recovery runtime
не включён; эта приёмка не закрывает fix-input-recovery или стадии продукта.

## Проверки

- 7 новых unit-тестов: допустимые клавиши/модификаторы, physical keyCode RU/EN,
  repeat до keyUp, reset без второго Down, synthetic, смена конфигурации, default
  double Shift, сохранение/повреждённые данные, отказ регистрации и OFF/ON.
- Полный набор: 1149 тестов без failures/skips; логи `.build/hotkey-test-final.log`.
- Build, Release и protocol: `.build/hotkey-{build,release-final,protocol}.log`.
- Живой v2: SHA256 `fa9ee173040c14ece3862602c56f414daed222e3998fec62c987b091252d100c`.
  Собственный TextEdit `recovery-pilot-textedit-20261017.txt`, без clipboard.
  Control–Option–K: converted → undone, исходный `ghbdtn` восстановлен по AX.
  После сброса double Shift: converted → undone с тем же точным исходником.
  Metadata-логи: `.build/hotkey-live-outcomes.log` (v2 PID 72418).
- Сохранённое Control–Option–K восстановилось при перезапуске v1 → v2.
- Отдельный собственный процесс проверил exclusive reservation: ON → -9878
  (занято), OFF → 0 с успешным unregister, ON → -9878. Настройки ON восстановлены.
- UI проверен по AX и скриншоту; убран перенос подписи «Клавиша».
  Итоговый выбор возвращён на double Shift; auto OFF/sound ON/launch-at-login OFF.

Первый v1 использовал non-exclusive регистрацию, которая не гарантирует отказ
при другом регистранте. По контракту локального SDK CarbonEvents.h заменено на
kEventHotKeyExclusive; именно v2 подтвердил реальный конфликт между процессами.

Живые нажатия сделаны ранее разрешённым CGEvent-драйвером с проверкой заголовка
только собственного тестового окна. Физическое удержание не объявляется проверенным:
защита autorepeat проверена детерминированными тестами. Конфликт-ошибка UI проверена
контроллерным тестом; системная эксклюзивность проверена отдельным процессом.

## Итог

CI `1ad421c` зелёный: https://github.com/cramen/LSwitch/actions/runs/39177132460
(build, Release, 1149 tests, 27 protocol groups, strict SwiftLint). Первое замечание
complexity=11 исправлено выделением обработки обычного ввода без изменения порядка.
OpenSpec strict: 7/7. Все пять задач change выполнены.

Обычная `.build/LSwitch.app` обновлена и запущена, SHA256
`da73579a71014bd71366e36e305f4304496617ad416122ae0142d5132755f738`.
В установленной версии повторены double Shift converted/undone и точный AX-исходник.
Новая настройка видна в UI, выбран двойной Shift, enabled ON, auto OFF, sound ON.
Прежняя сборка сохранена в `.build/LSwitch-before-hotkey-20261019.app`.
Старые scratch-runner, ожидающие SHA 513b по обычному пути, больше не подходят
без явной актуализации ожидаемой сборки; прежняя приёмка остаётся привязанной к старому SHA.

## Дополнение: Option+Space

Разрешено отдельное сочетание Option+Space без Control/Command; «Пробел» добавлен
в список клавиш. Голый пробел, Shift+Space и Option с буквами по-прежнему не допускаются.
Добавлен тест persistence, modifier validation, repeat, reset и обычного пробела.
Полный набор — 1150 тестов без failures/skips; Release build успешен.

В собственной TextEdit-фикстуре Option+Space дал converted/undone с точным возвратом
`ghbdtn` без добавочного пробела. При активном Option+Space обычный Space дал
`ghbdtn `, подтверждённый AX и точным selectText. Первый запуск драйвера без ожидания
доставку plain Space не подтвердил; повтор с wait:300 подтвердил её и в control,
и с активным сочетанием. Логи `.build/option-space-{test,outcomes,plain-active}.log`.
После теста возвращён двойной Shift; default приложения не изменён.
