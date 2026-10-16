# Проверка восстановления ввода — 2026-10-16

Продолжение `fix-input-recovery`, D7.3. Выполнено 3/14 задач; change не готов
к архивированию. Production factory, обычный replay permit и runtime wiring
нового recovery-владельца остаются недоступными.

## База и компонентные проверки

Коммит `4905175ee22974ed9a9ebfb039bf09c1b6ac3a7e` прошёл
[CI](https://github.com/cramen/LSwitch/actions/runs/38806072752): build, 731 тест
без ошибок, strict SwiftLint — 0 нарушений в 225 файлах.
Лог: `.build/checkpoint-4905175-ci.log`.

D7.3 добавляет отдельные sender/target identities, общий ledger в
RecoveryIsolationSession, RecipientTapDriver и scoped capture из настоящего
EventTapCore callback. Диагностический tap не декодирует неизвестный ввод
до attach и после detach. Обычный путь EventTapCore по умолчанию сохраняется.
Новые 30 компонентных тестов driver/session/router выполнены без skip.

Общий прогон: **761 тест, 0 failures, 3 skipped**;
`.build/input-recovery-isolation-final-{build,test}.log`. Все три пропуска —
прежние real-global-tap проверки: nonce keyUp не доставлен в текущем окружении.
Это не положительная приёмка доставки. Старый snapshot
`.build/checkpoint-3f1a307-lint` с EventTapCore из `3f1a307` воспроизводит
**688 тестов, 0 failures, те же 3 skipped**;
`.build/baseline-688-current-environment-test.log`. Предыдущий sandbox startup
snapshot не дошёл до тестов и сохранён отдельно. Сравнение не устанавливает
конкретную OS/TCC причину недоставки.

После исправления parent IPC и финального lifecycle выполнен повторный общий
build/test: 761 тест, 0 failures, те же 3 skipped. Логи:
`.build/input-recovery-isolation-checkpoint-{build,test}.log`.

Первый общий прогон завершился SIGSEGV в тестовом XCTAssertNotNil: reflection
обращался к Unmanaged временного CGEvent после освобождения объекта. Восемь новых
assertions проверяют Bool без reflection/dereference; продуктовый контракт
владения не менялся. Исходный лог: `.build/input-recovery-isolation-test.log`.

Независимые review проверили driver, session/router, child IPC и parent flow.
Исправлены предел frame вместе с LF, ошибка финального flush, порядок child exit
перед driver stop, поздний mailbox failure и запрет exit 0 для незавершённого опыта.

## Попытки двухпроцессного опыта

Child запускается только из собственного signed executable. У него одно
фиксированное NSTextView; IPC содержит nonce/sequence, команды и четыре fixture
marker. Пределы вместе с LF: request 512 байт, reply 1024; максимум 32/34 frames.
Известные отрицательные пакеты при утечке gate идут в обычный super dispatch.
Payload редактора не передаётся. До GUI-приёмки это только диагностический контур.

Первый кандидат SHA
`9a330324bec1a3022c1d60c88bec5e41094a509148ee2aa4f76d723b457accc3`
завершился `setup_timeout` через 10049 мс. Prefix/challenge не отправлены,
capture session не создана; child exit 0, stderr пуст, cleanup выполнен.
Локаторы: `.build/recovery-isolation-first.{jsonl,stderr}` и
`.build/recovery-isolation-candidate-manifest.json`.

Parent перешёл с FileHandle.read(upToCount:) на bounded POSIX read, чтобы короткий
готовый frame не ожидал полного буфера. Второй кандидат SHA
`c30e6f4e4ff4db3cdedea3b4e0d2f450442c7753334c42dc984e35241e63ac19`
получил ответы и завершился `focus_snapshot_failed` через 4390 мс:
active=false, focused=false, sequence 32. Текст fixture неизменён, received пуст,
клавиши не отправлены. Child exit 0, stderr пуст, cleanup выполнен.
Локаторы: `.build/recovery-isolation-v2.{jsonl,stderr}` и
`.build/recovery-isolation-candidate-v2-manifest.json`.

Read-only системные флаги подтвердили `CGSSessionScreenIsLocked=true` и
`kCGSSessionOnConsoleKey=true`. Пользователю предложена ручная разблокировка;
обход блокировки не выполняется. Capture, изоляция двух PID и ввод в recovery
редактор пока не приняты. Прохождение postToPid через session tap ещё не установлено.

Рабочий bundle `.build/LSwitch.app` не заменялся; SHA:
`7f52d970e38630d83ded9806d2ffecc15503060f9ebe4e9cf92837b32f67c61f`.
Обычный LSwitch восстанавливался после опытов; PuntoSwitcher/Caramba не запускались.
Автоматических обращений к clipboard и payload-журналов в опыте нет.

## Оставшиеся границы

Потеря защиты до adopt сохраняет sealed buffer, но его раскрытие пока недоступно:
report отмечает retainedBeforeAdoption/preAdoptLossUnresolved. Disable-return и EOF
не отменяют pending native/AX команды и не снимают Down/Up debt. Ожидания start/stop
ограничены 500/250 мс; это не отмена зависшего native tapCreate. Cleanup сообщается
только после фактической очистки. Системная проверка в разблокированной сессии
остаётся обязательной.

## CI текущего контура

Коммит `eaab146ba9297adc4d74aac62efd0ed3510d0109` прошёл
[CI](https://github.com/cramen/LSwitch/actions/runs/38854830163): build,
761 тест без failures/skipped и strict SwiftLint — 0 нарушений в 248 файлах.
Лог: `.build/checkpoint-eaab146-ci.log`. Требование CI для этого среза выполнено;
локальные 3 skip и блокировка живой приёмки этим удалённым прогоном не закрываются.
