## 1. Чистый контракт завершения

- [x] 1.1 Ввести отдельные типы результата текста, журнала собственной мутации и cleanup disposition по D1; сохранить `noOwnedMutation`, `recoveredObserved`, `recoveryUnconfirmed` без потери информации в обёртках. Проверка: unit-тесты фиксируют submission до setter/post, отрицательный ответ не отменяет попытку, no-owned путь требует действительного маршрута, unknown не выдаёт обычный успех, receipt или новую мутацию.
- [x] 1.2 Реализовать чистую машину владения очередью с generation и взаимоисключающими verified replay / recovery transfer. Проверка: управляемые перестановки timeout, cancel, позднего callback, повторного завершения и пустой очереди с опасным выделением дают ровно одного владельца, без двойной доставки или удаления.

Проверено 2026-10-15: исходные 19 тестов ledger и 4 regression-теста request wrappers
дополнены revision-наблюдением cleanup и защитой от nested финализации. Финальные
`make build` и полный `make test` — 567/567, 0 failures, 20:46:46 МСК; независимый
review CLEAN. Это завершение чистых контрактов, не включение рабочего recovery:
runtime пока не создаёт ledger и EventTapCore ещё не использует detach.
Одиннадцать новых тестов реальной очереди проверяют часть 3.1; она остаётся открытой
до интеграции и проверки lifecycle. Логи `.build/input-recovery-final-{build,test}.log`.

## 2. Адаптеры конвертации

- [ ] 2.1 Перевести прямой AX-конвертер на журнал мутации и структурированный cleanup, не ослабляя проверки текста, диапазона, identity и разрешений. Проверка: тесты setter success/error, позднего изменения и постоянно недоступного readback различают отсутствие мутации и неизвестное восстановление; успешный AX и точный undo сохраняются.
- [ ] 2.2 Перевести clipboard-конвертер с AX и native selection на тот же контракт, сохранив независимое владение clipboard. Проверка: обе production-регрессии `select → missing state → Paste=0` сохраняют удержанные события в recovery вместо опасного replay; оригинальный clipboard восстановлен только при своём changeCount, более новое копирование не затирается.
- [ ] 2.3 Подключить disposition к DEBUG Unicode, сохранив read boundaries, packet policy, inverse preflight и запрет повторной записи. Проверка: persistent count=999, частичный/ignored batch, ignored Right, cancellation до/после Down и exact undo не скрывают неизвестный cleanup; healthy control остаётся успешным, default Unicode не включается.

Частично выполнено 2.1: opt-in AX-адаптер журналирует фактический setter, возвращает
структурированный cleanup и требует bound receiver contract до записи. Модельные
регрессии проверяют nil readback, поздний setter, error после мутации, точный inverse,
защищённый/сменившийся контекст, отмену и nested финализацию. Production contract
остаётся unavailable; обычный runtime работает без нового ledger. Системный допуск
и подключение к решению об очереди не приняты, поэтому 2.1 не закрывается.

Частично выполнено 2.2: opt-in clipboard-адаптер и per-post hooks сохраняют отдельные
mutation/cleanup и clipboard ownership; 21 новая regression-проверка. Review исправил
canonical-equivalent foreign prefix перед cleanup и потерю исходного clipboard после
unresolved Copy. Общий локальный build/test: 616/616, 0 failures; production receiver
contract отсутствует, runtime не создаёт ledger. Реальный P1 в обычном режиме ещё
не считается исправленным, 2.2 остаётся открытой до интеграции.

Частично выполнено 2.3: opt-in Unicode использует bound receiver contract и журналирует
native/Unicode отправки до каждого post. Двадцать одна новая проверка покрывает
persistent count=999, ignored/partial selection и text packet, ignored Right, отмену,
late completion, exact inverse и самостоятельный outstanding key debt. При подключённом
ledger отсутствие receiver contract запрещает snapshot/подготовку и мутацию. Production
binding отсутствует, обычный runtime не создаёт ledger, DEBUG Unicode по умолчанию выключен.
Проверки вошли в локальный срез 686 тестов. Последующий общий прогон 688/0 также
подтвердил две регрессии гонки final external isValid после permitsReceipt в clipboard/Unicode.

## 3. Владение событиями и жизненный цикл

- [ ] 3.1 Добавить atomic detach в InputEventBuffer/EventTapCore и убрать безусловный replay из defer/endInputHold/deinit. Проверка: реальные удержанные копии в компонентных тестах сохраняют порядок и generation при detach, исходный владелец не может использовать их повторно; остановка/пересоздание tap, modifier debt и частичные Down/Up не вызывают скрытый post или drop.
- [ ] 3.2 Ввести RAM RecoveryCoordinator и связать его с OFF, Secure Input/TCC/tap-loss и graceful quit через заменяемые lifecycle-адаптеры. Проверка: OFF прекращает перехват, очередь и состояние опасной цели остаются доступными; отмена quit сохраняет запись, подтверждённое удаление выполняется один раз, позднее восстановление прав не запускает replay; crash не моделируется как durable storage.

Частично выполнены 3.2/4.1: чистые RAM coordinator/admission и 28 тестов связывают
operation, PID с birth time и hold-token; квоты проверяются до append, seal/claim
однократны. Gate loss и отрицательные lifecycle edges необратимо отменяют старый
допуск даже при ABA; hide/OFF не удаляют payload, delete/quit/cancel имеют явные
intent tokens. Связь с production capture/gate и обычным runtime ещё отсутствует.

Добавлена граница явного раскрытия: одноразовый intent связан с coordinator и записью;
hide/delete и новое раскрытие инвалидируют прежний результат. Двенадцать тестов
проверяют отсутствие чтений до принятого intent, повторные и чужие запросы, hide→show ABA,
reentry и сохранность исходной очереди. Это компонентная реализация, задачи остаются открытыми.

Дополнительно реализованы app-owned RecoveryOperation и scoped CapturePort: 13 тестов
проверяют сохранность очереди после потери tap-владельца, unavailable handover,
отказ/повтор adopt, foreign receiver, квоты и одновременные append/seal/detach.
Seal выполняется до критической секции gate, чтобы исключить обратный порядок locks.
Production CapturePort не подключён; обычного replay permit у нового пути ещё нет.

## 4. Допуск и системный приёмник

- [ ] 4.1 Реализовать RecoveryAdmission с резервом одной pending-записи, 256 событий и 64 KiB логического UTF-16 payload, связанный с process instance, generation и готовностью gate. Проверка: unavailable/lost gate, уже pending recovery, превышение лимита и невозможность ограниченного handover отказывают до selection/Copy/Paste; приближение к порогу не обрезает уже удержанную очередь и не продлевает mutation lease 400 мс.
- [ ] 4.2 Подготовить и проверить системный кандидат per-PID quarantine/admission с отдельным протоколом допуска. Проверка в собственном приёмнике: фактическая доставка и изоляция, порядок injected/original, focus changes, tap-loss/disable, Secure Input, late submitted selection/text packets, Down/Up, modifiers, shortcuts и mouse; marker/order не выдаются за renderer ACK. До полного подтверждения кандидат остаётся unavailable для собственной мутации; ограниченный уже выполненный keyUp probe не закрывает задачу.

Частично выполнено 4.2: изолированная DEBUG-сборка на базе `777c2cb` прошла baseline,
late-before-admission и намеренный disable fail-open на собственном NSTextView,
с реальным text/caret результатом и отдельным worker run loop gate. SHA бинарника
`1ce16fa257981e16d38d40c22258c9187e9ee2d0d7517a2dfe7f748912869375`.
Нет подтверждения внешнего renderer, полной клавиатурной матрицы и изоляции двух
процессов; gate по-прежнему не допущен к production.
Следующая изолированная сборка SHA
`83dae73c1aabb135e555af6fcbcd9778a9527f896589cd024ccd0a89291d3cfe`
дополнительно подтвердила позднее исполнение уже admitted пары после close и
доставку ровно одного paired Up после закрытия при ранее admitted Down. Отрицательный
контроль без Down debt по-прежнему блокирует Up. Это own-PID результаты, не полный допуск.

D7.1 design описывает следующий чистый кандидат RecipientGateState/NativeDispatchRegistry:
раздельные стадии отправки, bounded registry, парный Up и lost latch. Его тесты сами
по себе не разрешают production prearm, обычный replay или own-only drain после OFF.

Чистый кандидат реализован: 22 теста registry/markers/gate проверяют эти переходы,
включая конкурентные release и loss. SystemProcessIdentity добавляет чтение PID+birth
вне callback; 3 проверки используют собственный процесс и отрицательные контроли.
Общий build/test после исправления foreign-coordinator ack: 726/726, 0 failures;
логи `.build/input-recovery-ownership-{build,test}.log`, независимые review CLEAN.
Системный bridge D7.2 и production wiring не входят в этот результат.

D7.3 реализован как диагностическая интеграция общего ledger, driver, CapturePort
и двух собственных процессов. Добавлены 30 компонентных проверок; локальный прогон
761/0 failures содержит 3 skip прежних real-global-tap тестов. Старый snapshot 688
воспроизводит те же skip. Живые попытки завершились до отправки клавиш: исправлено
чтение короткого IPC frame, затем обнаружена заблокированная macOS-сессия.
После разблокировки v3 подтвердил обход session tap адресным postToPid:
capture=0, per-PID head блокирует Down, Up доходит без изменения fixture.
V4 захватывает через per-PID head: 2 события/16 байт приняты и переданы в RAM,
повторный prefix после detach подавлен без новых чтений. Challenge Down заблокирован;
parent-редактор принимает ввод, после EOF child исходный фрагмент и RAM-черновик
доступны повторно. Cleanup=true. Это отдельная проверка D7.3, не полный допуск 4.2;
потеря защиты до adopt, modifiers/mouse/shortcuts и runtime wiring остаются открытыми.
Подробности и точные бинарники — `docs/acceptance-2026-10-16.md`.

DEBUG bridge с тем же Core registry добавил 5 модельных проверок callback-протокола;
локальный общий прогон — 731 тест, 0 failures/skipped, лог
`.build/input-recovery-registry-bridge-test.log`. Они не доказывают системный nil-return.
Живой own-NSTextView кандидат SHA
`a3e9844b79351e414f80726fafb3434772a2ea23fa1b2d8cf0e61f8b03581456`
получил observationComplete/cleanup=true во всех шести опытах, включая legacy control;
протокол `.build/recovery-recipient-v2-summary.json`. При disable поздний callback
заблокировал Down, а Up дошёл до receiver без изменения текста: lost не закрыл ledger
(Prevented=0, Unknown=1, Unresolved=2). Первый timeout из-за ожидания bypass обеих клавиш
сохранён отдельно; v2 проверяет точное разбиение пары и ordered tail==receiver.
Это наблюдение ограничений доставки, не receiver ACK, replay permit или закрытие 4.2.

## 5. Локальный интерфейс восстановления

- [ ] 5.1 Создать заранее подготавливаемое recovery-окно и меню без активации рабочего системного пути до 4.2. Проверка: по умолчанию видны только причина/приложение/счётчики, явное раскрытие создаёт локальный RAM-редактор, обычное ручное выделение/копирование работает; закрытие/Escape лишь скрывает окно, удаление и quit требуют явного подтверждения, сбой активации не возвращает очередь старой цели.
- [x] 5.2 Реализовать проверяемую текстовую проекцию и упорядоченное представление нетекстовых событий, сохранив исходную запись. Проверка: текст, surrogate/IME/dead-key неоднозначность, shortcuts, навигация, мышь и частичные пары не превращаются в выдуманную итоговую строку; raw events не исполняются, до раскрытия payload нет в UI/AX, автоматические clipboard/file/log/network записи отсутствуют, ручное копирование не удаляет очередь.

5.2 выполнена; 5.1 выполнена частично: AppKit-окно и независимая UI session имеют 16 тестов
metadata-first, раскрытия, RAM-черновиков, hide/reopen, подмены записи и удаления.
Projector/reader проходят 21 проверку строгого UTF-16, порядка событий, бюджета,
документированных modifier bits и redacted descriptions; фрагменты означают только
eventPayloadOnly. Локальный срез 686 тестов завершён без failures/skipped.

DEBUG preview с fixed RAM fixture/fake gate подтвердил metadata-first, ручное
копирование/вставку и сохранность ASCII-черновика после Escape/reopen; отмена удаления
сохранила запись. Повторный live-прогон подтвердил отсутствие payload/reveal и disabled
Delete после подтверждения. Найденные старые счётчики 8/38 исправлены: новая живая
сборка показала 0 событий/0 байт, disabled Delete и отсутствие reveal/payload.
Локаторы — `.build/recovery-window-preview-counts.json` и полный протокол в
docs/acceptance-2026-10-15.md. Production gate,
handover и graceful quit реальной очереди этим preview не приняты, 5.1 остаётся открытой.

5.2 принята отдельно по 21 projector/reader-тесту, 12 reveal-тестам, живой проверке
раскрытия/ручного копирования и зелёному CI688. Независимый review подтвердил все
критерии этого пункта: представляется только eventPayloadOnly без нормализации,
исполнения или выдуманной итоговой строки; неоднозначные IME/dead-key данные не
декларируются завершённым текстом. Это не приёмка IME-конвертации или production capture.

## 6. Общая приёмка

- [ ] 6.1 Прогнать интеграционную матрицу трёх движков и жизненного цикла с управляемыми барьерами. Проверка: original P1 и healthy controls, stale AXValue/foreign range, permission ABA, late packet отдельно от late callback, потеря приёмника, пустая очередь, насыщение reservation, OFF/deinit/quit и новые запросы при pending сохраняют данные/единственного владельца; обычный успешный путь сохраняет порядок, TIS, caret/tail, clipboard и receipt undo.
- [ ] 6.2 Выполнить живые проверки отказа и следующего ввода только в собственных тестовых документах с принятым gate. Проверка: после неоднозначного cleanup уже удержанные события доступны в RAM, старое выделение не получает их автоматически, переход фокуса/отказ активации и маршрутизация shortcuts/mouse видимы и проверены; ручное раскрытие/копирование, закрытие окна, OFF и quit проходят выбранный UX. Отдельно записать потерю контроля над дальнейшим физическим вводом при отзыве прав/forced exit, восстановить исходные настройки; неподтверждённые конфигурации оставить отказом до мутации.
- [ ] 6.3 Выполнить `make build`, `make test`, строгий CI и независимый review исправления; обновить документацию и OpenSpec по точным бинарникам. Проверка: зелёный CI, протоколы model/system/live с границами доказательств и без payload, `openspec validate --all --strict`, отсутствие автоматического закрытия stage0/1/2 или bridge; синхронизация и архивирование этого change только после полного выполнения его критериев.

Исторический срез 686/0 сохранён в `.build/input-recovery-window-{build,test}.log`.
Следующий компонентный build/test 23:04:21 МСК — 688 тестов, 0 failures/skipped;
логи `.build/input-recovery-finalization-{build,test}.log`. Он включает исправления
final-validation race и UI-счётчиков, но не будущие candidate gate/wiring-файлы.
CI `06a95f7` подтвердил checkpoint 688: build/test и strict SwiftLint без нарушений.
CI `955b006` подтвердил срез 726: build/test, 0 failures/skipped и strict SwiftLint
без нарушений в 221 файле; `.build/checkpoint-955b006-ci.log`. CI `4905175` подтвердил
731 тест и strict lint без нарушений в 225 файлах. Готовность runtime не следует
из количества компонентных тестов.

Финальный повторный build/test также прошёл 731/731 без failures/skipped:
`.build/input-recovery-recipient-final-{build,test}.log`. Независимый review CLEAN;
статические ограничения шести Swift-файлов соблюдены. CI `eaab146` подтвердил
D7.3/761 без failures/skipped и без lint-нарушений в 248 файлах. Локальные 3 skip
и системная приёмка требуют разблокированной сессии; gate/runtime не закрываются.

Всего 14 задач. План готовит реализацию, но не объявляет system gate или recovery UI
готовым исправлением. Реализация чистых контрактов допускается первой; включение
обычного рабочего профиля зависит от системного допуска 4.2 и живой приёмки 6.2.
Контролируемые probes и тестовые сценарии не объявляются включённым рабочим профилем. Старый опасный replay
не является разрешённым rollback. Новые внешние разрешения и установки не подразумеваются
ранее выданным разрешением на конкретный тестовый драйвер.
