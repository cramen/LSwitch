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
обход блокировки не выполняется. На этом этапе capture, изоляция двух PID и ввод
в recovery-редактор не были приняты.

После подтверждённой пользователем разблокировки третий кандидат из `3882051`
с SHA `33b49f81fbd3f1a40a747dd5c894afc5c8f286720e66c9877abd8ab09d394082`
дошёл до active/focused receiver и собственного выделения. Отправлены два prefix
пакета через postToPid; session capture получил **0 событий/0 чтений payload**.
Per-PID head заблокировал Down, а Up дошёл до tail и NSTextView. Текст и выделение
fixture не изменились. Итог `session_capture_unobserved`, 1000 мс, child exit 0,
stderr 0, cleanup=true. Пустая recovery-запись принята, но это не приёмка сохранения
реального префикса. Локаторы: `.build/recovery-isolation-v3.{jsonl,stderr}`,
`.build/recovery-isolation-v3-manifest.json`. Подпись проверена с доступом к keychain;
sandbox-only codesign ранее не видел доверие сертификату.

Этот опыт подтвердил обход общего session tap адресным postToPid. Следующий
диагностический кандидат выбирает capture в per-PID head до selection; исходный
маршрут оставлен отдельной опцией для сравнения. Ограничения допуска 4.2 сохраняются.

Четвёртый кандидат SHA
`dd21f71d8b790363f7a6aa9848e28ba60fcb9693bee9ac6f88756ad2c20bd640`
с `--recovery-isolation-capture=recipient` подтвердил реальный capture/handover.
За 909 мс получено interactive_ready: captured=2, UTF16=16 байт, payload reads=2,
adopted/detached=true. Child не получил prefix, его текст/выделение неизменны,
changeCount=0. После detach повторная prefix-пара также подавлена: суммарный
fixtureSuppressed=4, очередь и reads не выросли. Challenge Down заблокирован,
только Release дошёл до tail/child, headBlocked=1. Это nil-return и наблюдение
NSTextView, не ACK всех способов мутации и не полный допуск 4.2.

CUA подтвердил metadata-only окно с 2 событиями/16 байтами. Явное раскрытие
показало точный фиксированный фрагмент; редактирование его RAM-копии в другом
процессе работало. Cmd+E закрыл собственный child: UI показал недоступность защиты
и снова скрыл payload. После повторного раскрытия исходный фрагмент и отредактированная
копия сохранились. Clipboard не использовался. Финал operator_finished через 66432 мс:
child exit 0, cleanup=true, stderr=0, revealCount=2, events=2/bytes=16, reads=2;
replayAuthorized/productionGateAccepted=false. Обычный LSwitch восстановлен.
Локаторы: `.build/recovery-isolation-v4.{jsonl,stderr}`,
`.build/recovery-isolation-v4-manifest.json`, `.build/recovery-isolation-v4-ui.json`.

После этих изменений полный локальный `make test` прошёл **776 тестов без failures
и skipped**. Включены 9 новых driver/endpoint и 6 Session/Router регрессий;
прежние три real-global-tap проверки в разблокированном окружении также выполнились.
Логи `.build/recovery-isolation-perpid-{build,full-test}.log` и
`.build/recipient-capture-targeted-tests.log`; независимый review CLEAN,
`openspec validate --all --strict` — 6/6. Исторические пропуски не переименованы в PASS.

Рабочий bundle `.build/LSwitch.app` не заменялся; SHA:
`7f52d970e38630d83ded9806d2ffecc15503060f9ebe4e9cf92837b32f67c61f`.
Обычный LSwitch восстанавливался после опытов; PuntoSwitcher/Caramba не запускались.
Автоматических обращений к clipboard и payload-журналов в опыте нет.

## Storage-only передача после потери защиты

D7.4 добавляет отдельное завершение локального capture: router больше не выдаёт
новые tickets и ждёт нулевого числа уже вошедших callbacks, включая count/copy/counters.
Связанный с конкретным seal одноразовый proof разрешает только передачу RAM-владения.
Ожидание возвращает pending без блокировки MainActor; gate, replay, receipt и
unknown/key debt не переопределяются. Изначальный допуск и protected finish не ослаблены.

Независимый review выявил и закрыл два случая: чужой seal с тем же binding не должен
отравлять кеш proof; уже отделённый private batch должен переживать потерю gate до
adopt без повторного detach/claim. Добавлены 13 регрессий, targeted — 39/0 failures,
полный `make build`/`make test` — **789 тестов без failures/skipped**.
Логи `.build/recovery-retirement-targeted-tests.log`,
`.build/recovery-storage-final-{build,test}.log`; review Core и App — CLEAN.

Контроль receiver без tap/gate/capture выполнен на SHA
`fdaa01a48881e290bfe73fd157cffb1225750f3ea230608645340b8c7f691f38`:
два пакета дошли до обычного dispatch, exact text/caret=true, changeCount=1.
За 529 мс получены финальный ответ, EOF, child exit 0 и cleanup=true; stderr=0.
Это положительный контроль чувствительности receiver, не safety PASS.
Локаторы `.build/recovery-isolation-v5-control.{jsonl,stderr}`,
`.build/recovery-isolation-v5-manifest.json`.

Отказ до selection проверен на SHA
`4f057bb6f7f02f9ae83669603ed466a5dd0aa52670918e276d8d9ed1db654365`:
настоящий test driver остановлен, beginFixtureSelectionCommand отказал,
submission/capture/posted=0, исходный текст неизменён, changeCount=0.
Итог pre_mutation_refused, 385 мс, child exit 0, cleanup=true, stderr=0.
Локаторы `.build/recovery-isolation-v6-preselect.{jsonl,stderr}`,
`.build/recovery-isolation-v6-manifest.json`.

Финальный кандидат SHA
`73feec6610fe03c22e344b6e6efb0872d9ea0b69f9614d1a31d8480a83754082`
в режиме stop-before-adopt действительно остановил driver после capture двух событий,
но до передачи очереди. За 405 мс получено storage_ready:
storageOnlyAdopted=true, events=2/bytes=16, reads=2, неизвестная selection-команда
остаётся в ledger. В child received=[], текст/выделение неизменны, changes=0.
После stop новые клавиши в child не отправлялись. CUA подтвердил unavailable-предупреждение,
скрытый payload, явное раскрытие, редактирование копии и сохранность исходного фрагмента
и черновика после Cmd+E/EOF и повторного раскрытия. Clipboard не использовался.
Финал operator_finished через 58643 мс: child exit 0, cleanup=true, stderr=0,
revealCount=2, прежние events/bytes/reads. Локаторы:
`.build/recovery-isolation-v7-storage.{jsonl,stderr}`,
`.build/recovery-isolation-v7-storage-ui.json`, `.build/recovery-isolation-v7-manifest.json`.

Тот же v7 повторил обычный режим: capture2/16, поздний prefix подавлен,
challenge Down заблокирован, Release дошёл без изменения текста; storageOnlyAdopted=false.
Interactive-ready через 778 мс, финал через 18771 мс, child exit 0, cleanup=true.
Локаторы `.build/recovery-isolation-v7-normal.{jsonl,stderr}`.
Driver в финальном JSON — явно сохранённый snapshot **до** cleanup; верхний
cleanupCompleted относится к завершившемуся shutdown. Рабочий bundle после всех
опытов восстановлен с прежним SHA; PuntoSwitcher/Caramba не запускались.

## Оставшиеся границы

Disable-return и EOF не отменяют pending native/AX команды и не снимают Down/Up debt.
Storage-only снимает ограничение раскрытия уже принятой очереди после локального
quiescence; при незавершённых callbacks она остаётся у прежнего владельца.
Ожидания start/stop ограничены 500/250 мс; это не отмена зависшего native tapCreate.
Проверен controlled stop собственного driver, а не отзыв TCC/Secure Input во время
настоящей пользовательской конвертации. Дальнейший физический ввод при потере
контроля не объявляется защищённым. Runtime wiring, обычный replay permit,
graceful quit и полная матрица modifiers/shortcuts/mouse остаются открытыми.

## CI текущего контура

Коммит `eaab146ba9297adc4d74aac62efd0ed3510d0109` прошёл
[CI](https://github.com/cramen/LSwitch/actions/runs/38854830163): build,
761 тест без failures/skipped и strict SwiftLint — 0 нарушений в 248 файлах.
Лог: `.build/checkpoint-eaab146-ci.log`. Требование CI для этого среза выполнено;
локальные 3 skip и блокировка живой приёмки этим удалённым прогоном не закрываются.

Следующий коммит `455dcb9c8e7a8eb63c80307627135051bdde77ac` также прошёл
[CI](https://github.com/cramen/LSwitch/actions/runs/38877272494): build, 776 тестов
без failures/skipped, strict SwiftLint — 0 нарушений в 252 файлах.
Лог `.build/checkpoint-455dcb9-ci.log`. Он включает исправление per-PID capture
и протокол живого v4; задача 4.2 и runtime wiring по-прежнему не закрыты.
