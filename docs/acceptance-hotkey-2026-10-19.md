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
