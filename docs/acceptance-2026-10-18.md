# Приёмка fix-input-recovery — 18.10.2026

Продолжение `acceptance-2026-10-17.md`. Проверяется отдельный DEBUG TextEdit pilot,
привязанный к собственному `.build/recovery-pilot-textedit-20261017.txt`.
Рабочий профиль recovery пока не включён. TextEdit 1.19 (404), macOS 14.5 (23F79).
Проверки не используют clipboard; PuntoSwitcher и Caramba остаются выключенными.

## Подтверждённый срез CI

Коммит `011c0b8db9285590ea6818fd569e720406039304` прошёл
[CI 39145461422](https://github.com/cramen/LSwitch/actions/runs/39145461422):
Debug/Release build, 1030 unit-тестов, recovery protocol и strict SwiftLint.
Следующие локальные оптимизации и live-кандидаты в этот CI-срез не входят.

## Здоровый путь TextEdit пока не принят

Перед каждой попыткой собственное поле содержало тестовое слово, каретка стояла
после него, раскладка ABC. Только заголовок тестового окна проверялся драйвером
перед CGEvent-клавишами. Двойной Shift запускал настоящий pipeline LSwitch.
Лимит mutation lease 400 мс не увеличивался.

| Кандидат | Unit-тесты | Наблюдение | Приёмка |
| --- | ---: | --- | --- |
| v2 | 1049 | AX engine около 387 мс; `text-completion-unconfirmed`; текст изменился, TIS нет | FAILED |
| v3 | 1059 | `context-changed-after-selection`; `logicalFailure=expired`; текст исходный, слово выделено | FAILED |
| v4 | 1080 | AX engine около 392 мс; `final-state-not-settled`; `logicalFailure=expired` | FAILED |

Во всех попытках обычная доставка и receipt не разрешены; открылась RAM recovery
с нулём удержанных событий. Это отказ здорового пути, а не подтверждение исправления P1.
В v3/v4 причина expiry записана непосредственно. В v2 отдельной причины lease в
протоколе ещё нет; длительность сама по себе не доказывает причину отказа.

SHA-256 исполняемых файлов:

- v2: `285770c2c5f7f5900f75b0f118b4b37bc5d78b29d91cad9db48b7eea7b2caa49`.
- v3: `96fd02b79faecd63e6f463929351523c40f2e823a83285c3cacb06fe38a0c6b7`.
- v4: `8026432246beca8e37e856c65fe646eb93d67e0c60e3e33d6402d1b5fed7189b`.

Manifest каждого кандидата: `.build/recovery-textedit-pilot-vN-manifest.json`.
Протоколы: `.build/recovery-textedit-pilot-v2-full-system.log`,
`.build/recovery-textedit-pilot-v3-system.log`,
`.build/recovery-textedit-pilot-v4-system.log`.
Точный исходный срез v4 сохранён в `.build/recovery-textedit-pilot-v4-source`;
`.build/recovery-textedit-pilot-v4-final-check.log` подтверждает 1080 тестов,
0 failures/0 skipped и 7 protocol-групп.

## Диагностика повторных проверок

Измеряются только число вызовов и суммарное время, без текста/clipboard/путей.
Суммы snapshot включают внутренние guards и не складываются с остальными колонками.

| Группа | v3: вызовы / мс | v4: вызовы / мс |
| --- | ---: | ---: |
| Request | 92 / 160,03 | 156 / 11,52 |
| Source | 92 / 1,65 | 156 / 2,10 |
| Protected | 92 / 30,34 | 156 / 54,16 |
| Focus | 92 / 46,69 | 156 / 81,71 |
| Context | 46 / 54,21 | 78 / 76,89 |
| Snapshot inclusive | 6 / 210,73 | 9 / 167,22 |

Canonical combined validation в v4 существенно сократила повторный request guard,
но внешние AX guards по-прежнему повторяют проверки цели. Следующий шаг — объединить
их с полным профильным guard, сохранив свежие document/window/element/PID+birth,
фокус, защиту поля, исходную раскладку и исходный deadline. Undo требует отдельного
точного receipt anchor; успешный API и совпадение текста не объявляются renderer ACK.

## Окно восстановления и выход

В приложение добавлено собственное стандартное App menu. В v2 проверены Cmd+Q,
отмена выхода, повторный Cmd+Q и подтверждение удаления собственной тестовой записи.
В v3/v4 подтверждён штатный выход через тот же диалог. Все три runner завершились
с `launcherExit 0` и восстановили обычный LSwitch. Вызов SystemUIServer из неуспешного
опыта v1 больше не повторялся.

Обычный bundle не заменялся; SHA-256 его бинарника:
`7f52d970e38630d83ded9806d2ffecc15503060f9ebe4e9cf92837b32f67c61f`.
Ни forced timeout v1, ни успешный quit v2–v4 не принимают системный gate или
преобразование. Задачи 2–4/6 остаются открытыми, прогресс change — 4/14.

## V5: полный guard и точный Undo anchor

Debug/Release build, **1095 тестов, 0 failures/skips**, protocol 7 групп — PASS.
Manual/typed-undo/protection/receipt прошли независимый review. Добавлен независимый
от старой Session и раскладки receipt target, exact UTF-16 span/caret для inverse,
и полный путь для custom/неподтверждённого provenance. Найденная отдельно граница
effective automatic context передана на исправление; auto этим срезом не принимается.

Кандидат SHA `a3ee7cce95f27bf2499b32fd4747a66ab66476102f2ee0f11f0564f64b9916ae`,
manifest `.build/recovery-textedit-pilot-v5-manifest.json`, source
`.build/recovery-textedit-pilot-v5-source`. Первый test compile остановился из-за
изменения тестового файла во время сборки; после полного freeze повтор
`.build/recovery-textedit-pilot-v5-final-test.log` прошёл полностью.

Live healthy **FAILED**, PID 59208, 20:43:27 МСК: engine около 391 мс,
`final-state-not-settled`, `logicalFailure=expired`, RAM 0 событий. TIS не менялся;
драйвер остановился при появлении recovery-окна и не послал второй double Shift.
Поэтому живой Undo ещё не проверен. Cmd+Q/подтверждение завершили candidate штатно,
runner вернул `launcherExit 0` и восстановил ordinary LSwitch.

Профильных context boundaries стало 96: request 192/15,67 мс, protected 192/66,37 мс,
focus 192/129,66 мс, context 96/92,43 мс, snapshot inclusive 9/182,32 мс.
Это показывает, что простая замена outer guard на полный Profile guard переносит
повторную работу, но не убирает её. Следующий шаг должен объединять дублирующиеся
границы без промежуточного внешнего вызова, сохраняя два стабильных наблюдения
после записи и исходный deadline. Protocol:
`.build/recovery-textedit-pilot-v5-system.log`, driver: `.build/recovery-textedit-pilot-v5-driver.log`.

## V6–V8: живой AX, Undo и потеря readback

V6 (1108 тестов) снова отказал на final settlement: SHA
`c63789c0fe8382ce8e7ec3f325b81398fc0dccb00f3dd74dd04d580fa654e395`, PID 61265,
88 context boundaries/9 snapshots, logical expired. V7 (1111 тестов) перенёс
acceptance внутрь второго стабильного чтения: SHA
`995cd6b70cbfa4550a3663ed90a1cac20327b8989bc5709ad8bdbf06b0bc706d`, PID 61627,
65 boundaries/7 snapshots до отказа; также expired. Оба кандидата штатно завершены,
ordinary восстановлен. Логи `.build/recovery-textedit-pilot-v{6,7}-system.log`.

V8 дополнительно убрал начальное дублирование focus/protected внутри canonical
metadata boundary. До payload/setter остаются свежие закрывающие focus/protection,
source/foreground с обеих сторон и concrete request/lease closing. Generic/custom
путь не менялся. **1112 тестов, 0 failures/skips**; полный source и manifest
`.build/recovery-textedit-pilot-v8-{source,manifest.json}`. SHA:
`b29d0f4ff4f3f8388e8dbcd60f7264ce680d6825ab9d478f0644b6991258f6b6`.

Живой healthy PID 61884 подтвердил 5 последовательных операций: RU→EN, точный
Undo, следующий RU→EN запрос, EN→RU с хвостовым пробелом и точный Undo. TIS
подтверждён в обоих направлениях; реальные результаты `converted`/`undone`,
не две независимые конвертации. После последнего Undo обычный ввод дал ожидаемые
`ghbdtn  x`, recovery не возникла. Полный operation time 325–412 мс включает
подготовку до lease и завершение после обычной доставки. У пятой операции
после `undone` logical finish отметил `expired`; это **не** доказательство запаса
по latency или приёмка удержанного logical tail на границе срока. Нужно отдельно
проверить его и сократить накладные расходы. Исходные 400 мс не увеличивались.
Логи `.build/recovery-textedit-pilot-v8-{system,driver,english-driver,next-driver}.log`.

На том же бинарнике PID 61939 запущен `missing-after-selection` только для своего
документа. После успешного собственного selection setter и подтверждённого выделения
приняты 2 события/4 байта тестового ввода; инъекция имеет статус `injected`,
missingReads=1, selectionAttempts=1, blockedWrites=0. Текст не заменён, TIS остался ABC,
receipt/replay отсутствуют. `ghbdtn` осталось выделенным; явное раскрытие RAM показало
`x` и keyUp. Следующий тестовый `y` при активном quarantine не изменил поле или запись.
Выход драйвера с кодом 1 вызван сменой foreground на recovery UI после захвата;
metadata подтверждает полноценный prefix, это не inconclusive инъекция.

OFF сохранил 2 события/4 байта и доступность раскрытия, а новый тестовый `z` штатно
заменил собственное выделение: перехват остановлен, прежний `x` не воспроизводился.
После возврата ON запись осталась; Quit Cancel сохранил её, повторное раскрытие
показало `x`. Подтверждённое удаление только тестовой RAM-записи завершило candidate;
runner вернул `launcherExit 0`, ordinary восстановлен. Логи
`.build/recovery-textedit-pilot-v8-{missing-system,missing-driver,missing-next-driver,off-driver}.log`.
Clipboard не использовался. Enabled возвращён ON, auto OFF, sound ON.

Найдено неточное описание `.off`: после возврата общего ON оно всё ещё называло всё
приложение выключенным. Текст уточнён до остановленной защиты исходного приложения;
новый ввод не блокируется, старая RAM-запись остаётся. Это последующая UI-правка,
не часть перечисленного SHA v8.

## D7.9: реальные Secure Input и отключение tap

Отдельный snapshot на базе `011c0b8` с диагностическим overlay: parent SHA
`96a82a88952c1db027078ffee9f37c913858cc5278d0cbd7b7a9b51be4626946`, receiver SHA
`5a085243d6899633e4349c7203935d243f9725c09594a3486c0bd60d2fadff8d`.
Manifest `.build/system-fault-candidate-v1-manifest.json` фиксирует предзапусковую
сборку; фактические native результаты — `.build/system-fault-v1-summary.json`.
Изолированные 46 Core tests, 24 protocol-группы и App build прошли.

| Сценарий | Фактическое наблюдение |
| --- | --- |
| Control | Пара дошла, fixture изменился ожидаемо |
| Secure до arm | Отказ до capture, поле неизменно |
| Head disable до arm | Отказ до capture, поле неизменно |
| Secure после capture | 2 события/16 байт сохранены; поздний postToPid дошёл |
| Head disable после capture | 2 события/16 байт сохранены; поздний postToPid дошёл |
| Tail disable после capture | 2 события/16 байт сохранены; поздний postToPid не дошёл при живом head |

Во всех случаях child exit=0/EOF/finalReply, cleanup=true, debt=false,
pairInconclusive=false, watchdog=false. Собственные Secure Enable/Disable — 1/1,
финальный global enabled=false. Reveal и Quit Cancel сохранили fixture; после явного
удаления ordinary восстановлен. Новый monotonic continuation latch не открывается
после отмены quit: поздние start/disable/retire не отправляют новые Down. Balancing Up
к исходному process instance остаётся отдельным cleanup. Watchdog вооружается до Enable.

Это **только postToPid в собственный child**. Физический/global HID не проверен;
nativePrivacyAccepted=false и productionEnabled=false. Не принимаем обход Secure/
head как защиту от приватного ввода или renderer ACK. Общие задачи 2–4/6 остаются
открыты до производственного подключения, остальных движков и полного системного допуска.

## D7.10: глобальный synthetic HID

Отдельный кандидат parent SHA
`64548019e579b2595a58da50ddc1cc296248b90a0cd8cb1309015ff3f8249ed6`, receiver SHA
`596905c087192fa0fc6897fa2efbd096c47f4a8cf19e2d28c061b6f0f1af6b25`;
source/manifest `.build/system-fault-hid-v1-{source,manifest.json}`.
1112 unit-тестов, 26 pure protocol-групп, Debug/Release — PASS.
Маршрут выбирается явно; default остаётся pid. Обычная пара проверяет foreground
перед каждым post, а balancing Up после потери фокуса всегда адресован прежнему PID+birth.

HID control подтвердил реальную доставку двух fixture-событий и ожидаемое изменение
поля. Secure-after-capture сохранил 2 события/16 байт в RAM; поздняя synthetic HID
пара дошла до child, а сохранённый prefix не воспроизводился. Явный reveal показал
fixture; после подтверждённого удаления child exit0/EOF/finalReply, cleanup=true,
debt=false, watchdog=false; Enable/Disable1/1, global enabled=false. Обычный LSwitch
восстановлен. Логи `.build/system-fault-hid-v1-{control,secure-after}.jsonl`.

Это проверяет handover **после явного сообщения о Secure Input**, а не отсутствие
захвата между реальным включением Secure Input и его обнаружением. Этот интервал
и физическая клавиатура ещё требуют проверки; privacyGuardAccepted=false сохраняется.

CI `f8bd26d` прошёл Debug/Release/test/protocol, но отклонил 12 SwiftLint замечаний:
multiple-closure syntax, optional initialization и сложность двух diagnostic handlers.
Исправлены явные `then:` labels, implicit nil и выделены небольшие handlers без
изменения порядка действий. Результат следующего CI фиксируется отдельно.

## D7.11: интервал до обнаружения Secure Input

DEBUG mode `secure-capture-window` вооружает capture без исходного prefix, ждёт
подтверждённого Secure Input и отправляет фиксированную пару **до** искусственного
вызова observeSecureInput. V1 увидел доставку без capture; для исключения истёкшего
lease добавлены явные current checks до post и после ответа child.

V2 parent SHA `d033f7703d26044db217a56b765508664743f44346af9a664a3d274a7c7684f4`,
receiver SHA `539afddd17d3f86004c02d5e6263882f0d4cb6a086affbb987eb6beee05ae336`.
Manifest `.build/secure-capture-window-v2-manifest.json`. **1113 unit-тестов**, без
failures/skips, **27 pure protocol-групп**. Проверка expiry отдельно подтверждает,
что возврат тестовых часов назад не оживляет отказавший capture.

На этом бинарнике HID observation получил `deliveredWithoutCapture`:
secureCaptureCurrentBefore=true и secureCaptureCurrentAfter=true, capturedEvents=0,
capturedBytes=0, countReads=0; child получил ровно prefixDown/prefixRelease и
подтвердил ожидаемые текст/каретку. Secure enabled/owned проверены при наблюдении;
до этого программный fault latch не закрывался. Это отдельное наблюдение защиты
synthetic HID от захвата во время Secure Input при живом admission, не результат
expiry или преждевременного handover.

Положительный HID control на том же V2 также прошёл. Оба child завершились с
exit0/EOF/finalReply, cleanup=true, debt=false и watchdog=false; собственные
Enable/Disable1/1, итоговый global enabled=false. Пустая тестовая recovery-запись
удалена явно, ordinary восстановлен. Логи:
`.build/secure-capture-window-v2-{observation,control}.jsonl`.
Физическая клавиатура и весь системный допуск этим опытом не заменяются;
privacyGuardAccepted=false сохранён.

CI `c446e62` прошёл build/test/protocol, но оставил одно замечание `vertical_whitespace`
в диагностическом helper. Лишняя пустая строка удалена в следующем срезе.

## Реальный отзыв и возврат Accessibility

Коммит `35420507bd9a9424eff209d090f3ba868704234a` прошёл полный
[CI 39155342553](https://github.com/cramen/LSwitch/actions/runs/39155342553):
Debug/Release, 1113 тестов, recovery protocol и strict SwiftLint.

Отдельный lifecycle v9 SHA
`7a8bc6a6c3eed4a9df653ec124d377436feaf09ad61d28e571e67228e05ccd4d`, PID 64002,
manifest `.build/recovery-lifecycle-v9-manifest.json`. В своём TextEdit fixture
`missing-after-selection` снова подтвердил injected, selectionAttempts=1,
selected=true, prefixEvents=2/countReads=2/prefixBytes=4. После системной
аутентификации пользователя явно наблюдались LSwitch Accessibility OFF и ON.

При OFF приложение в 21:49:31 МСК записало «Не хватает разрешений — перехват остановлен».
Окно recovery сообщило о недоступной защите и сохранило 2 события/4 байта;
явное раскрытие показало `x` и keyUp. Собственный `ghbdtn` остался выделенным,
автоматического replay не произошло. После ON в 21:50:11 Event tap запущен снова;
исходный текст и RAM-запись остались прежними, старая операция не продолжилась.
Quit запросил подтверждение удаления только тестовой записи, завершился штатно;
runner подтвердил `launcherExit 0` и восстановил ordinary LSwitch. Accessibility
возвращён ON. Другие записи разрешений не менялись агентом.

Логи `.build/recovery-lifecycle-v9-accessibility-{driver,system,revoked,restored}.log`.
Более ранние переходы разрешений в том же журнале не используются как отдельная
приёмка: учитывается только явно выполненный и наблюдённый агентом цикл OFF→ON.

Отдельный сценарий Input Monitoring на том же v9 подготовил собственную RAM-запись,
но системный список «Мониторинг ввода» не содержит LSwitch. Отдельного переключателя
для отзыва нет; новую запись/разрешение не создавали. Приложение получает доступ к
прослушиванию при существующем Accessibility. Независимый переход Listen permission
не принят на этом стенде; цикл Accessibility не переименовывается в такой тест.
Тестовая запись удалена через штатный Quit, ordinary восстановлен. Локатор подготовки:
`.build/recovery-lifecycle-v9-input-monitoring-driver.log`.

## Физический ввод во время преобразования

V10 SHA `321bde3dae0251971505df2e3f178aa9ac2434db181ed2c78009e2f2897614b4`,
PID 64873; manifest `.build/recovery-physical-v10-manifest.json`. В отчёт добавлены
только capturedEvents/UTF16Bytes/payloadCountReads, без текста, flags или keycodes.
1113 тестов прошли без failures/skips. Пользователь выполнил физический ввод в своём
тестовом TextEdit; агент не отправлял клавиши в этом опыте.

Первый запрос шёл при sourceLayout=ru и не требовал смены TIS. Второй, в 21:59:46,
подтвердил sourceLayout=en→ru, результат `converted`, captured=3:4:2. Пользователь
сообщил `приветч`; чтение собственного окна подтвердило тот же текст. Значит физическая
клавиша действительно попала в удержанную очередь, а не только пришла после завершения;
исходный текст не затёрт, дублирования символа нет, коррекция раскладки в очереди сработала.

После ordinary completion логический finish отметил `expired`; result остаётся
converted, RAM recovery не возникла. Это подтверждает доставку в данном опыте, но
**не закрывает** задержку, обработку logical tail на deadline и всю системную матрицу.
Лог `.build/recovery-physical-v10-system.log`. Штатный Quit завершил candidate,
runner подтвердил `launcherExit 0` и восстановил обычный LSwitch; enabled ON, auto OFF,
sound ON. Пользовательское выделение текста после опыта не выдаётся за final caret
самой операции.

## Предпосылка native sender и bounded AX reader

Собственные reserved native headers исключаются из глобального logical input до
payload чтения, только при своём source PID и реально выделенном shared serial.
Fixture-prefix выделен в отдельный namespace, чтобы продолжать моделировать
пользовательский ввод. Callback-регрессии проверяют pre-arm, active lease, foreign
PID/namespace и закрытое поколение; recognition не объявляется admission.
Срез 1119 тестов/Release/27 protocol-групп прошёл локально. CI `3b39981` нашёл только
complexity=11 в callback; эквивалентные early-return условия объединены с сохранением
short-circuit порядка. Clipboard/Unicode sender этим ещё не подключены.

Конкретный AXBoundedSnapshotAccess гарантирует guard перед первым getter и после
каждого getter. Только для него убраны два внешних дубля Profile; arbitrary provider
и fault injection сохраняют прежние guards. Четыре новые регрессии проверяют точные
границы, смену документа внутри count, защиту после selection и oversized отказ без
payload/fallback. Полный набор — **1123 теста, 0 failures/skips**. Заодно fixture
старого synthetic-marker теста перестал наследовать реальные удерживаемые модификаторы:
ожидание обычной буквы теперь явно задаёт flags=[]; production classifier не менялся.

V11 SHA `893f2d5e6f7dcdb9828a9edc1b42fca7fc7713fb89cef9c7be7cfbe2d8eee479`, PID 66612,
manifest `.build/recovery-bounded-v11-manifest.json`. Четыре живые операции
converted/undone/converted/undone прошли с TIS RU↔EN, profileFault=none и logicalFailure=none.
Во всех операциях 9 полных snapshots, 63 context boundaries вместо 81. Полный operation
time — 343/317/395/409 мс; это ещё не latency acceptance или доказанный устойчивый запас.
После Undo AX-текст собственного документа содержит точный `цщкдв` с U+00A0, не ASCII space.
Логи `.build/recovery-bounded-v11-{system,driver}.log`. Candidate завершён штатно,
ordinary восстановлен. Физический ввод относится к V10, не объявляется повторённым на V11.

## Подготовка native-команд без системной отправки

CI `d0e23c0` зелёный: run 39160274250. Следующий компонент NativePreparedBatch
резервирует полные пары до submission, сохраняет порядок, native Unicode и flags,
изолирует копии от вызывающего кода. Проверены неверные/неполные пары, закрытый gate,
предел 256 событий и отказ огромного selectCharacters до генерации массива.
Ни один тест этого компонента не вызывает post или системное управление окнами.
Полный набор: **1132 теста, 0 failures/skips**; `.build/native-prepared-test.log`.
В первом прогоне выявлено сохранение старого marker после повторного присвоения;
fallback через обновление CGEventSource исправил roundtrip, тесты payload/order прошли.
Тестовый emoji был заменён разрешённым BMP-текстом: действующая UnicodePacketPolicy
намеренно запрещает surrogate packets, её ограничения не расширялись.

Пользователь подтвердил наличие только трекпада. Физическая средняя кнопка и
right/otherMouseDragged этим не проверены; CGEvent mouse emitter не запускался.
Задачи 2.2/2.3/4.2 остаются открытыми; подготовки пакетов недостаточно для рабочего sender.

## Bound native transport

NativeDispatchBinding связывает свежий token журнала, reservation и непосредственный
post, проверяя исходный process instance и запрет повторного/reentrant send.
Keyboard/Unicode emitters принимают optional binding через receiver contracts;
старые клиенты без binding сохраняют прежний transport. Отдельный AX observation
profile не допускается в native binding. Никакой head/tail факт не становится ACK.

Десять новых проверок используют подменный post: submission-before-post, повтор,
закрытие gate внутри beforeSend, чужой token, Up до Down, потеря процесса, баланс
admitted модификатора после focus loss/close, healthy keyboard и одноразовый Unicode.
Недоставленный Up сохраняет debt; повторная отправка Down или всего batch отсутствует.
Полный набор: **1142 теста, 0 failures/skips**. Логи:
`.build/native-binding-{test,release,protocol}.log`.
Это компонентная интеграция, без системных событий и изменения установленной сборки.
Живой receiver contract и native профиль подтверждения результата ещё отсутствуют;
задачи 2.2/2.3 и общий runtime этим срезом не закрываются.
