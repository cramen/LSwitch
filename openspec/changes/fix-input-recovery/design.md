## Context

Мотивация — в proposal.md. Контрпримеры используют скомпилированный Core 513b и
тестовые адаптеры, без UI, AX IPC, General pasteboard и реальной отправки клавиш.
В Unicode после select(7) постоянный characterCount=999 даёт failed, Down=0,
hold→release и оставшийся диапазон 0..<7; следующий `next` заменяет оригинал.
Production clipboard с native и AX selection воспроизводит тот же эффект при
постоянно отсутствующем readState: failed, Paste=0, clipboard восстановлен,
но следующий ввод заменяет слово. Локаторы: `.build/research-incoherence/`
`results.json`, `production-results.json` и соответствующие Research.swift.

В исходном runtime 513b источники опасного replay — Converter.defer,
EventTapCore.endInputHold и deinit; исход завершения не передаёт наверх безопасность
собственного выделения. Новые opt-in компоненты разделяют эти состояния, но ещё
не подключены к обычному runtime. Ожидание ещё одного AX-снимка не решает постоянный отказ.

## Goals / Non-Goals

**Goals:** единый проверяемый исход cleanup для трёх движков; единственный владелец
уже удержанных событий; отсутствие автоматической доставки в неоднозначную цель;
готовность аварийного пути до мутации; восстановление под явным управлением пользователя.

**Non-Goals:** гарантировать действия стороннего приложения после уже принятого им
запроса без контракта получателя; восстанавливать RAM после crash; автоматически
исполнять произвольные команды из сохранённой очереди; включать Unicode/VS Code
профили или заменять незакрытые матрицы этапов 0–2. Расширение браузера не требуется.

## Decisions

### D1. Результат текста и безопасность доставки — разные состояния

Ввести монотонный журнал собственной мутации и структурированный исход завершения:
`noOwnedMutation`, `recoveredObserved`, `recoveryUnconfirmed`. Это не синонимы
converted/failed. Submission отмечается ДО setter/post; отрицательный возврат
setter, отсутствие readback или истечение lease не отменяют уже сделанную попытку.
Успешное текстовое подтверждение также обязано подтвердить допустимую каретку.

`noOwnedMutation` допустим только по журналу отсутствия отправленной собственной
мутации. Для него не требуется AX cleanup; обычный маршрут доставки должен оставаться
действительным. `recoveredObserved` требует доказательств адаптера, а не факта вызова
cleanup. Для native-команд нужно отличать queued/admitted от наблюдаемого восстановления;
старое пустое выделение не считается подтверждением исполнения отложенного batch.
`recoveryUnconfirmed` терминален для операции: запрещены fallback, новый текстовый
пакет, обычный успех, undo, обучение, звук успеха и слепая смена раскладки.

Неизвестный исход не должен теряться при оборачивании ConversionRequest, document
checks или завершении clipboard-транзакции. Clipboard восстанавливается своим
владельцем с прежней защитой чужого копирования независимо от исхода input cleanup.

Cleanup evidence не является разрешением replay. Итог `replayAuthorized` требует
одновременно действительного маршрута, безопасного состояния получателя и закрытия
каждой собственной отправки доказательством завершения, предотвращения до admission
либо отдельным принятым `observedUnderProfile` по D1.1.
`recoveredObserved` при остающейся pending-команде даёт `recoveryRequired`.
Отметки `adapterReturned` и `admitted` сами по себе не закрывают отправку.
Наблюдение cleanup получает opaque token до свежего чтения. Token связан с operation
identity и revision журнала; новая editor submission, её unknown/completion либо
начало следующего наблюдения инвалидируют старое подтверждение. Поздний callback
не может повторно записать ранее безопасную каретку после новой мутации.

Отдельный факт outstanding key debt фиксирует реально отправленный Down, для которого
не удалось отправить необходимый Up. Даже receiverCompleted для Down и безопасная
каретка не закрывают этот долг. Он запрещает ordinary submission, replay и receipt
независимо от noOwnedMutation (включая modifier-only путь); неподтверждённый Up не
изображается фиктивной отправкой. Первая версия сохраняет такой факт до recovery
без автоматического снятия. После finish поздний callback не меняет принятое решение.

#### D1.1. Принятый практический контракт отдельного профиля

16.10.2026 пользователь делегировал выбор для качества продукта после предъявления
вариантов в `runtime-contract-decision.md`. Выбран B: отдельное профильное основание
наблюдаемого результата, без выдуманного renderer ACK. Критерий изменён явно;
само решение не означает готовности provider, ordinary delivery или системного gate.

Первый кандидат — прямой AX TextEdit 1.19 (404) на проверенной macOS 14.5 (23F79),
native text area и поддерживаемая прямая раскладка. Binding включает operation/token,
PID+birth time, удерживаемые AX element/window, контекст документа и версию профиля.
Каждый последовательный setter требует success и свежего полного точного UTF-16
снимка с ожидаемым диапазоном/кареткой и guards до/после чтения. Финальное состояние
подтверждается отдельно. Другие движки и приложения не наследуют этот контракт.

Первый профиль ограничивает снимок редактора 65536 UTF-16 units отдельно от квоты
удержанных событий. До payload читается допустимый character count; строка запрашивается
через AXStringForRange только для [0,count], затем count сверяется повторно вместе
с точными UTF-16 и диапазоном. Неподдержанный parameterized API, неверный count или
превышение предела дают отказ; fallback к неограниченному AXValue отсутствует.

Валидное отсутствие работы отделяется от fault только для ручного запроса без
expectedWord/replacement: полный профильный snapshot содержит collapsed caret и
не содержит слова перед ней. Повторный свежий guarded snapshot должен точно
совпасть по UTF-16 и каретке; до и после него нет собственной отправки, отмены или
fault. Такое `noWorkObserved` сохраняет noOwnedMutation без receipt/TIS/звука успеха;
обычная доставка всё равно требует отдельного актуального маршрута. Nil snapshot,
неверные count/range, expected-span mismatch, чужое выделение, отказ API или контекста
не относятся к этому исключению и сохраняют sticky fault/recovery.

Ledger хранит профильное основание отдельно от receiverCompleted. В профильном
режиме error/timeout, потеря identity/прав, отмена или неоднозначное чтение создают
sticky fault: последующее совпадение либо поздний ответ не разрешают новую мутацию,
receipt или replay. После fault AX cleanup становится read-only; повторного setter
для восстановления выделения нет. Сохранённый ввод передаётся в RAM recovery.
Строгий путь с настоящими доказательствами остаётся отдельным контрактом.
Admission, quota, lease, key debt, готовность recovery и событийная матрица 4.2
сохраняются; будущие произвольные изменения самим приложением не гарантируются.

### D2. Атомарное владение удержанным вводом

Очередь имеет generation и ровно один путь завершения: подтверждённая обычная
доставка либо atomic detach в RecoveryCoordinator. Поздний callback старого
поколения не доставляет и не забирает события повторно. Deinit не выполняет post.
Жизненный цикл владельца RAM не зависит от пересоздания/остановки event tap.
При неподтверждённом собственном выделении recovery нужен даже для пустой очереди.

Новая физическая активность после handover не добавляется в старую запись.
Запись включает исходный порядок и metadata уже принятых событий. Незавершённые
пары Down/Up и modifier debt учитываются явно; отправка балансирующего Up не
должна превращаться в replay неотправленного Down или произвольной команды.
Это отдельные тестируемые решения, не следствие одного массива CGEvent.

#### D2.1. План подключения владельца операции и capture port

Владелец уровня приложения `RecoveryOperation` должен удерживать ledger,
reservation, buffer и hold-token независимо от времени жизни tap. Thread-safe
`CapturePort` связывает operation, hold-token и UUID конкретного tap. Связь публикуется
только после последовательности begin→bind и до первого принимаемого события;
callback старого tap не получает доступ к новой операции с тем же номером поколения.

Завершение capture соблюдает порядок admission: закрыть допуск → получить seal →
атомарно detach. Защитный gate обязателен до detach. Отсоединённый pending batch
остаётся у RecoveryOperation до успешного adopt, включая отказ или задержку coordinator.
Stop, deinit и timer только защёлкивают состояние; они не выполняют post/drop.
Обычная доставка требует отдельного принятого permit и не следует из завершения hold.
Это план wiring для 3.1/3.2/4.1; он не объявляет runtime подключённым.

Следующий recipient capture использует тот же port/reservation/retirement, но отдельную
политику заголовков: события выбранного per-PID endpoint вместо фиксированной fixture-пары.
Endpoint связывается с полным scope до начала захвата; этот режим не устанавливается
на глобальный tap. Зарегистрированные собственные native пакеты остаются в своём
gate-протоколе. Unicode length читается только для keyDown/keyUp после допуска;
modifiers/mouse/scroll сохраняются с нулевым текстовым cost и исходным порядком.
После retirement сохраняется metadata tombstone без новых payload reads.

#### D2.2. Подключение отслеживаемой операции к Converter

Явная optional factory отделяет старый runtime от нового tracked режима. Установленная
factory, вернувшая unavailable, запрещает hold/engine/mutation; переход в legacy после
такого отказа отсутствует. Factory может асинхронно подготовить worker до capture:
на время ожидания owner уже зарезервирован, повторный запуск запрещён. После ожидания
снова проверяются контекст, отмена и точная регистрация Session; устаревший контекст
не активирует capture, а уже созданная очередь остаётся у её владельца.
Новый Session удерживает один ledger для conversion,
разрешённого fallback и undo; ограничение профиля на AX проверяется до выбора движка.

Успешный engine receipt сначала остаётся кандидатом. Перед user-visible успехом
Session проверяет финальное evidence и подготавливает обычный маршрут без post.
Capture продолжается до атомарного commit: промежуток перед TIS и передачей очереди
не должен терять новый ввод. Очередь остаётся у app-owner до единственного commit. Fallback
разрешён только при отсутствии собственной отправки, fault и key debt.

TIS/readback выполняется после допуска финализации, но до доставки; коррекция
применяется к доставляемым копиям, а исходная запись не переписывается. Принятие
ownership и завершение доставки разделены: только после отдельного
`locallyDispatched` сохраняются undo/cache и вызывается сигнал успеха. Это локальное
завершение transport, а не renderer ACK. Отказ TIS сохраняет прежний partial-result
контракт без звука успеха.
Recovery-ветка не вызывает legacy release, не публикует receipt и не обучает автоматику.

Отказ transport до принятия очереди оставляет её исходному владельцу для recovery.
Нельзя выдавать второй claim после уже принятой обычной передачи. Для любого переноса
такого владения нужен отдельный монотонный контракт, а не повторный claim или post.
Для отказа до принятия transport и до первого claim вводится отдельная монотонная
отмена ordinary-authorisation. Исторический final decision остаётся неизменным,
текущая допустимость доставки становится recovery-only; единственный ещё не выданный
claim может перейти только recovery-владельцу. После ordinary claim этот переход
запрещён. Контракт transport: отказ до claim означает отсутствие post/передачи;
нарушение этого контракта не запускает повторную отправку или второй claim.
Пока настоящий обычный transport/полная защита не приняты, production factory
остаётся unavailable; компонентные проверки Converter используют явный тестовый provider.

Внешние проверки AX/NSWorkspace и callback-проверки контекста выполняются до критической
секции transport. Внутри неё допустимы только чистый однократный claim и проверка
сохранённых generation/health/quota; IPC и native post под capture/admission locks
запрещены. Принятие владения очередью не обозначает renderer ACK. Поздний отказ уже
принявшего transport не возвращает очередь прежнему владельцу и не запускает retry.

`commitOrdinary` синхронно принимает очередь и выдаёт отдельный completion handle.
Его claim callback после внешних проверок обращается только к чистым phase/binding/
ledger-состояниям; повторных AX, TIS, NSWorkspace или route callbacks под lock нет.
Session ожидает `locallyDispatched` либо `retainedFailure` отдельно. Внешний owner
остаётся занят до terminal completion; новые конвертации и ранняя публикация успеха
запрещены. Отмена ожидания только запрашивает сохранение у transport, не завершает
его преждевременно и не освобождает очередь. После принятого ordinary claim отказ
сохраняет данные у того же transport/owner с тем же claim; новый recovery claim и
повторная отправка не создаются. Pending/retained состояние доступно интерфейсу
через метаданные owner. Настоящий native transport и его временные/объёмные пределы
принимаются отдельно, до включения production factory.

Session удерживает bound engine, поэтому callbacks исходного ConversionRequest
(`isValid`, `beginMutation`, `canCleanup`) содержат только weak-ссылку обратно на
Session и возвращают false после её освобождения. Во время операции Session держат
runTracked и внешний app-owner; pending recovery продолжает принадлежать owner.
Успешное завершение должно освобождать Session/adapter даже при ещё сохранённом
профиле или receipt guard для undo: цикл engine → profile → request → Session
не является допустимым механизмом lifetime. Это проверяется отдельным deallocation test.

#### D2.3. Пауза логической обработки глобального tap

Отдельная scoped processing lease не удерживает native events и не подменяет
recipient capture. Пока она действует, глобальный tap возвращает исходное событие,
не применяет к нему коррекцию и не вызывает handler/detector/auto. После допуска
capture он сохраняет только ограниченный логический дубликат RawKeyEvent в RAM:
не более 256 событий и 64 KiB UTF-16, с общим сроком 400 мс. Это не recovery-запись
и не второй владелец удержанных CGEvent. Неуспех, истечение, focus/OFF/TCC очищают
только логический дубликат и прекращают новые payload reads; исходная held queue
остаётся у независимого app-owner. Legacy-путь без lease не меняется.
Общая маска tap включает scrollWheel для activity/lease; без lease прокрутка
по-прежнему проходит native, не попадая в legacy hold или raw decoder.

Begin публикует паузу до ожидания processingQueue→Main barrier. Уже поставленные
handler callbacks завершаются до допуска новой мутации. Синхронный metadata-only
счётчик callback activity закрывает гонку begin→recipient arm: новый физический ввод
до arm делает подготовку устаревшей, а не просто исчезает из notifyOtherKeystroke.
Проверка preCaptureReady и arm выполняются подряд на MainActor без await; повторная
проверка после arm не допускает мутацию при reentry/изменении активности.

Finish одноразово связывается с operation scope и экземпляром tap. Один Main блок
сначала применяет outcome/очищает прежний контекст слова, затем передаёт FIFO tail
и лишь после этого возобновляет обычные handler callbacks. Коррекция tail является
чистой функцией над снимками и соответствует принятому native transport interval;
исходные CGEvent не изменяются. Отдельный tail из per-PID сюда не добавляется, чтобы
не удваивать ввод. Ошибочный/устаревший finish не публикует хвост чужой операции.

Это внутренний компонентный контракт: main.swift и production factory пока его
не используют. Native flush, реальная смена фокуса, Secure Input и lifecycle должны
пройти отдельную системную приёмку до включения рабочего профиля.

#### D2.4. Обычный transport и сохранение частично отправленной очереди

После единственного ordinary claim полный scoped port передаёт закрытый batch
app-owned OrdinaryInputCustody. Для take нужны локальный quiescence proof, конкретный
seal и совпадение operation/process instance/hold/tap; это не разрешение renderer ACK.
Оригиналы изымаются из batch ровно один раз и никогда не изменяются для доставки.
Transport заранее создаёт отдельные копии; отсутствие копии не заменяется оригиналом.
Correction и post выполняются вне port/admission/custody locks.

Dispatch одноразовый, ограничен исходной admission-квотой и явным deadline. До каждого
post фиксируется attempt ordinal, после возврата — returned ordinal. Retention/loss/
истечение бюджета запрещают следующий attempt; уже зарезервированная попытка может
завершиться и входит в потенциально отправленный префикс. Это не ретроактивная отмена.
Reentry не запускает второй dispatch. Terminal capsule выпускается только после
quiescence и хранит полный оригинал вместе с metadata attempted/returned, без payload
в логах и без утверждения фактической обработки приложением.

Healthy completion освобождает reservation через отдельный completeOrdinary(proof).
При отказе Coordinator.adoptRetainedOrdinary(proof) принимает оригиналы с тем же
ordinary claim, а не выдаёт новый recovery claim. Чужой/reused proof отклоняется до
изъятия; отказ adopt оставляет capsule у transport/app-owner. При attempted>0 публичные
метаданные требуют сообщить, что часть событий уже могла попасть в исходное приложение.
Автоматического повтора нет. Старый recovery adopt не принимает ordinary claim.

Первый компонент использует только подменяемые copy/prepare/post границы в RAM.
Настоящий worker marker, переход gate к pass-through, CGEventTapPostEvent и его
системная приёмка подключаются отдельно; terminal local completion не становится
renderer ACK. Проверки включают каждый ordinal частичного отказа, copy failure,
cancel/deadline/reentry, lifetime, foreign/reused proof и rejected adoption.

#### D2.5. DEBUG recipient flush и атомарная публикация capture

Обычный `QueuedInputCorrection.corrected` сохраняет прежнюю политику Cmd/Ctrl/Option.
Строгая проверка новых native-пакетов отделена в `correctedTracked`: неизвестные flags
в интервале коррекции запрещают весь batch до первого post. Наблюдаемый у локального
CGEventSource бит `0x20000000` не получает разрешения по догадке; его профиль требует
отдельной проверки реального ввода перед включением transport.

App-owner регистрирует Session до запуска асинхронного arm. Один блок того же worker
run loop публикует recipient endpoint и активирует gate; callbacks не могут наблюдать
промежуток «gate protected, endpoint ещё отсутствует». MainActor ждёт готовность без
синхронной блокировки. Отмена/timeout закрывают одноразовую подготовку: поздний worker
block не восстанавливает scope. Проверка отпущенных mouse buttons относится только к
этому prearm; физический mouseDown после arm сам по себе не прекращает scoped capture.

Перед ordinary claim готовится один уникальный control keyUp с keyCode 0 и пустыми
flags, связанный с sender PID и operation/process instance. Он пока не признан
нейтральным для реального AppKit: до положительного control весь transport DEBUG-only.
Diagnostic fixture может заранее передать свою уникальную выделенную метку; production
должен выделять её сам. Повторной отправки marker нет. State хранит только его metadata
tombstone и weak transport; поздний или неправильный own marker подавляется даже после
обычного завершения и освобождения владельца.

Перед вызовом postWake фиксируется локальная in-flight reservation. Retention может
сохранить очередь во время этого вызова, но terminal capsule/result не публикуются до
его возврата; иначе поздний control мог бы прийти после снятия gate. Callback, пришедший
раньше возврата postWake, может закончить batch и route transition, но публикация всё
равно ждёт local quiescence этого вызова. Никакой remote delivery ACK из него не следует.
Deadline ограничен исходным immutable holdDeadline (begin + 400 мс), а не новым сроком
от момента commit; свежий preflight также явно expire-ит cached capture lease.

После единственного claim capture остаётся открытым до marker callback. Callback
закрывает новые route tickets, seal-ит admission и получает локальный quiescence proof,
после чего port передаёт оригиналы той же OrdinaryInputCustody. Копии, correction и
CGEventTapPostEvent(proxy) выполняются вне всех внутренних locks. Только полный
локальный returned-префикс позволяет переключить этот endpoint в normal pass-through
до возврата callback; это не receiver completion и не renderer ACK.
После этого принятого перехода unowned pass-through необратим для старого driver:
stop/health loss не возвращают новый ввод в retired capture tombstone. Собственные
control/native marker по-прежнему проверяются раньше этого прохода и не оживают.

Если финальный переход endpoint отказал уже после полного returned-префикса,
ещё не потреблённый успешный terminal proof однократно переносит полный оригинал
в новый retained proof с причиной routeUnavailable. Scope, seal, ordinary claim,
transport identity и attempted/returned сохраняются. Перенос и healthy consumption
взаимоисключаются под одним lock; прежний proof после переноса не завершает доставку
и не выдаёт originals повторно. Это монотонный отказ после локальной отправки,
а не второй claim, replay или доказательство недоставки уже отправленных событий.

Retention, deadline, lost/stop и отсутствие proxy не повторяют marker. Worker закрывает
локальный capture без post и повторяет лишь неблокирующую проверку quiescence. Пока
старые count/copy/counter callbacks не завершились, terminal result не публикуется.
После quiescence полный оригинал остаётся в terminal proof с тем же ordinary claim;
quarantine сохраняется. App-owner потребляет proof через существующие Coordinator
complete/adoptRetained методы; refused adoption не удаляет proof и не разрешает replay.

#### D2.6. Атомарный logical/native arm и профильный TextEdit pilot

Измерительный v3 подтвердил `.expired`: 92 вложенных request checks заняли 160 мс
до завершения шести snapshots. Следующая оптимизация объединяет проверку только
явно помеченного canonical Session request: opening выполняет host/capture preflight,
Profile — прежние свежие source/focus/protected/window/document/process checks и
foreground PID до/после, closing — конкретные RAM lease/deadline/revision/phase/ledger
без произвольных callbacks. Ticket однократен и связан с Session/operation/profile;
новый nested opening инвалидирует прежний. Сохраняются границы каждого snapshot/setter,
исходный срок 400 мс и sticky fault, а не разрешение между чтениями или через await.
Opaque provenance создаётся только при конструировании canonical request самим
Converter/Session. Public init и wrappers дополнительных validators его не сохраняют.
Generic request, unknown wrappers и undo пока используют полный прежний путь; это
промежуточный шаг реализации, а не исключение из обязательной приёмки undo.
Нужны regressions смены foreground при старом AX focus, source/Secure, reentry target/
revision/attempt/OFF, истечения срока внутри AX callback, foreign/stale/reused ticket,
исчезновения weak Session и дополнительного validator, ставшего false до payload.

Следующий opt-in DEBUG pilot связывает существующие компоненты, не включает factory
в обычном режиме до приёмки 4.2. Он ограничен явно переданным локальным тестовым
документом: AXDocument должен совпасть с file URL до любого payload/capture. Неполный
или ошибочный pilot-флаг завершает запуск; не включает обычный legacy-путь молча.
Подготовка профиля TextEdit остаётся metadata-only;
её binding, ledger и AX engine принадлежат одной Session. Общий изменяемый «последний
профиль» не используется. Tracked routing выбирает engine Session, а новый undo
получает собственную Session/profile с сохранением точного receipt target check.

После запуска ещё не вооружённого worker EventTapCore создаёт processing lease и
проходит barrier. PreparedEventProcessingArm содержит exact state/lease/scope и
исходный deadline. Native hold использует тот же начальный момент, а не новый срок.
Session регистрируется у внешнего owner до async arm. Один worker block под logical
lock проверяет epoch/activity/expiry, публикует native capture и затем ставит armed.
Публикация — только локальные locks/state, без MainActor/IPC/AX/payload callbacks.
Глобальный callback либо делает подготовку устаревшей до arm, либо читает logical
дубликат после публикации. Cancel/stop закрывают scoped запрос без повторного arm.

Runtime adapter — единственный потребитель native terminal handle/proof. Он сначала
передаёт proof в complete/adoptRetained Coordinator и лишь затем завершает отдельный
handle Session. One-shot retention callback отдельного handle вызывается вне его
lock и передаёт отмену native flush; два независимых флага без связи не допускаются.
После завершения Converter App wrapper одним processing finish
применяет outcome/очищает старое слово, затем доставляет FIFO logical tail. Legacy
очистка после этого не выполняется. Factory отказ не включает fallback в старый hold.
Pilot допускает только профиль TextEdit AX; остальные конфигурации отказывают до
мутации. Production включение требует отдельной живой проверки и lifecycle wiring.
Окна menu-bar агента получают штатное application menu с Cmd+Q, ведущим в тот же
applicationShouldTerminate/recovery confirmation. Выход проверяется без обращения
к SystemUIServer; наличие этого menu не снимает quarantine и не удаляет RAM самостоятельно.

Runtime выдаёт scoped invocation token до trigger и сохраняет занятость до отдельного
finish после outcome: повторный/busy trigger не может закончить чужую lease. Внешний
owner и runtime сохраняют Session/adapter при ошибке либо deinit Converter. Focus loss
необратимо останавливает операцию и сохраняет quarantine; OFF/TCC/tap-loss выполняют
retention и остановку scoped driver без replay. Quit сначала ждёт RAM handover, затем
использует прежнее explicit решение пользователя; удаление само не разрешает новый ввод
в неподтверждённую цель. onStateChange содержит лишь сигнал перечитать metadata.

Первый живой TextEdit pilot изменил fixture, но дошёл до final-state-not-settled
после истечения исходных 400 мс. Статический разбор обнаружил в context до шести
scalar AX reads: Role/Window повторялись при повторном получении document identity.
Узкая оптимизация объединяет свежие Role/Window/element Document в один
AXUIElementCopyMultipleAttributeValues, затем читает свежий Window Document при
необходимом fallback. Batch принимается только с точной формой/типами; неизвестное
значение не превращается в noValue или untitled. PID окна проверяется отдельно.

Версии TextEdit и системы кэшируются только внутри environment по свежему
process identity (PID + birth) и bundle identity/URL. Неизвестный процесс/application
или смена ключа инвалидируют запись. Role, window, document, focus, source и protected
не кэшируются. Число/порядок safety boundaries, полные snapshots, два stable чтения,
20-мс интервалы и предел 400 мс не меняются. Уменьшение metadata RPC не считается
доказательством успешного pilot или выполнения latency gate без нового live-прогона.

Повторный healthy pilot после этой оптимизации снова исчерпал 400 мс внутри AX engine
(`text-completion-unconfirmed`). Перед дальнейшими изменениями добавляются DEBUG
metadata-only counts и cumulative monotonic timings для requestIsValid, source,
protected, focus, context и snapshot. Измерения начинаются после prepare профиля;
snapshot явно inclusive: его время включает вложенные guards и не суммируется с ними
как независимая стоимость. Отчёт только читается после операции; hot path не вызывает
diagnostic observers, не пишет логи и не хранит текст, пути, URL или AX payload.
Текущий profileFault читается из связанного ledger. Это измерение не меняет порядок
проверок, два stable чтения, 20-мс интервалы, admission или исходный deadline.

V4 подтвердил уменьшение requestIsValid до 11,5 мс, но healthy операция снова
исчерпала 400 мс на final-state settlement. Следующий узкий шаг применяется только
к canonical manual request после успешного exact profile bind: внешние AX guards
делегируют тому же полному Profile boundary, а generic manual document wrapper
заменяется его более строгой проверкой element/window/document/process identity.
Custom validators, auto и generic undo сохраняют прежний полный путь. Receipt получает
отдельный source-independent target с сильным удержанием captured identity и fresh
проверкой документа без старой Session/ledger; transient nil generic document read
не может убрать этот guard. Добавление custom receipt guard теряет typed provenance.
Generic bind получает именно effective request после добавления document/context
wrapper: потеря provenance и дополнительный validator действуют также внутри каждого
profile payload boundary, а не только во внешней проверке перед setter.
Тот же delegation допустим для typed undo, только если capability несёт certified
anchor прежнего receipt и совпадающие exact saved original/converted/tail. Anchor
связан с подтверждённой конечной кареткой; первый snapshot до own submission обязан
совпасть по caret и UTF-16 converted+tail. Identity anchor проверяется на каждой
профильной границе; после собственной selection старый caret не проверяется.

Только TextEdit profile объединяет Subrole/ProtectedContent в один свежий AX batch.
Точная форма/типы обязательны; noValue/attributeUnsupported означают известное
отсутствие атрибута, иные ошибки, CFNull и malformed batch дают protected отказ.
Secure Input проверяется на MainActor, данные защиты не кэшируются. Это сокращение
metadata IPC не меняет полноту snapshots, два stable наблюдения, интервал 20 мс,
исходный deadline или requirement отдельной приёмки undo.

После v5 (healthy снова expired) шаг v6 ограничен двумя доказуемыми сокращениями.
В bounded snapshot reader закрывающий guard после count одновременно является
guard перед text read: между ними только pure bounds/NSRange. Profile observation
создаёт opaque ticket после pure binding/state checks и выполняет единственный full
guard внутри своего fresh read. Canonical prepared write получает отдельный API без
arbitrary validator: полный profile guard выполняется после prepare непосредственно
перед submission один раз; generic validator и receiver binding остаются прежними.

Observation подтверждения replacement синхронно возвращает тот же accepted snapshot
selection в finishWrite, вместо повторного snapshot без промежуточных external calls.
Значение не переносит разрешение через await: fresh guard перед следующим setter и
последующие stable/final snapshots сохраняются. Ticket acceptance, pending removal
и возврат selection между fresh read и использованием — только pure локальные действия.
Два stable чтения с 20 мс, max4, cleanup и 400 мс не сокращаются; объединение acceptance
с самим stable read пока не входит в этот шаг.
Runtime сохраняет только value snapshot отчёта перед освобождением successful attempt;
завершение старого await не перезаписывает статистику новой invocation. Logical failure
читается по exact lease либо берётся из результата finish, без новых AX/IPC/expiry effects.
Новая invocation очищает прежнюю статистику; ради диагностики Session/driver не удерживаются.

После v6 healthy снова истёк на final settlement. Следующий шаг объединяет
подтверждение pending submission со вторым стабильным чтением только canonical
профиля. Первое и второе чтения разделены прежним 20-мс await, каждое выполняет
полный свежий profile snapshot. Ticket создаётся до второго чтения, принимается
синхронно после его закрывающего guard; наружу возвращается лишь завершение этого
наблюдения, не разрешение для последующей записи. После await перед следующим
setter и при финальном cleanup остаются свежие проверки. Generic/custom settlement
не меняется. Отмена/смена цели/ошибка второго чтения оставляют pending command
неподтверждённой; позднее совпадение не очищает fault. Дополнительный третий snapshot
и соседние внешние guards того же canonical read больше не повторяются.

V7 сократил число полных границ, но свежий global AX focus остаётся главным расходом.
В canonical boundary начальные focus/protected reads дублируют закрывающие reads:
между ними читаются только metadata ранее связанного элемента, без payload или setter.
Следующий шаг оставляет fresh focus/protected после metadata и до любого payload/
submission, а source/foreground — с обеих сторон. Request/lease closing остаётся
последним. При смене фокуса/защиты во время metadata чтения закрывающая проверка
отказывает до payload. Generic/custom boundary сохраняет прежний порядок.

#### D2.7. Точный undo с типизированной целью предыдущего receipt

Подтверждённый canonical AX receipt может содержать внутренний AXProfileReceiptTarget:
profile ID, PID с birth, элемент, окно, exact document identity и подтверждённую final
selection. Anchor не удерживает старые Session/Profile/driver либо snapshot provider.
Его независимый fresh target guard не фиксирует прежний source: после успешного TIS
текущая раскладка уже другая. Public receipt и checkingTarget(custom) не сохраняют эту
provenance. Наличие одинакового текста или того же ledger её не заменяет.

Converter сохраняет typed anchor только после ordinary completion вместе с исходным
original/converted/trailingText и bundle identity. Новый undo получает свежие Session,
profile, lease и ledger. Старые undoContext/previousTarget проверяются при preflight;
запись undo потребляется один раз. Combined capability выдаётся лишь при exact UTF-16
совпадении сохранённого anchor с UndoRecord и параметрами inverse request. Nil,
неизвестная provenance и дополнительные validators сохраняют прежний полный путь.
Смена реальной цели после допуска необратимо отказывает, а не запускает другой путь.

Новый profile сравнивает typed old target со своими свежими element/window/document/
process observations на каждой boundary без второго комплекта AX RPC. До первого
собственного setter initial snapshot обязан иметь старую final caret и точный UTF-16
span converted+tail перед ней; NFC/NFD и замена NBSP на ASCII space здесь не эквивалентны.
После первого submission старая caret уже не является ожидаемой: допустимые собственные
переходы selection/text/finalCaret проверяются прежними per-step snapshots и ledger.
Финальный inverse receipt по-прежнему должен точно совпасть с сохранённым original.

Приёмка включает успешный RU/EN inverse с NBSP и decomposed Unicode, другой документ/
окно/процесс при том же тексте, перемещение caret к повторяющемуся слову, custom validator
внутри snapshot, устаревший/потреблённый undo и освобождение старой Session. Текстовые
payload anchors остаются в прежнем RAM undo; журналы получают только метаданные.
Предел 400 мс не меняется, а приёмка undo остаётся обязательной.

### D3. Подготовка допуска до первой мутации

RecoveryAdmission связывает reservation, целевой процесс/его экземпляр, поколение
операции и действующий системный gate. Неуспех prearm запрещает собственное
выделение, текстовую запись и команды Copy/Paste; путь не обходит отказ другим движком.
Одна незавершённая recovery-запись приостанавливает новые конвертации.

Кандидат gate — CGEventTapCreateForPid для захваченного процесса. Tap находится
после маршрутизации и может изолировать проблемный процесс, не перенаправляя мышь
и системные shortcuts в другой PID. Callback не читает текст редактора, не делает
AX/TIS/NSWorkspace IPC и не ведёт payload-журнал. Подготовка и проверки контекста
остаются на MainActor вне callback. Само создание tap не доказывает рабочую доставку.

Пробник `.build/recovery-tap-probe-appkit-idempotent-result.json` подтвердил только
own-PID admission order: после NSApplication.shared, при policy prohibited,
active=false/windows=0, head увидел один keyUp, proxy внедрил один keyUp, tail
получил `[injected, original]`. Запросов TCC не было. Предыдущий консольный вариант
вернул nil при head_create; это не доказательство общей недоступности per-PID tap.
CGEventTapPostEvent задаёт порядок внедрения перед возвращаемым callback событием,
но не подтверждает обработку редактором и не исправляет ignored Right.

Второй own-PID probe `.build/recovery-receiver-probe-result.json` подтвердил приём
baseline/control в очереди NSApplication.nextEvent и отклонение отправленного ранее
keyUp закрытого поколения: head blocked, tail/receiver его не наблюдали. Окно проверки
268 мс, active=false/windows=0, cleanup обоих tap выполнен. Это ingress AppKit для
трёх собственных keyUp, не editor ACK, не проверка внешнего процесса и не допуск 4.2.

Системный адаптер допускается только после проверки реальной доставки/изоляции,
переключения приложений, Secure Input, потери/выключения tap и баланса Down/Up.
Он не должен объявлять cached NSWorkspace/AX или activate() достаточным recipient ACK.

### D4. Ранее отправленные команды не исчезают по таймеру

Поколение операции закрывается при завершении. Заранее подготовленный gate должен
отклонять не допущенные ещё собственные команды старого поколения; допущенные Down
и необходимые Up учитываются раздельно. При невозможности сопоставить отправку
с admission адаптер не считается готовым. Статический общий synthetic marker
нельзя без проверки выдавать за token конкретной операции.

Per-PID tap не отменяет уже доставленный native event и не перехватывает AX RPC.
Движок обязан сообщать неопределённость таких команд. Проверка запоздалого пакета
в реальном получателе обязательна; чистый late-callback тест её не заменяет.
Порядок postToPid и cgAnnotatedSessionEventTap тоже требует самостоятельной проверки.
Если контракт отмены/доставки не принят, профиль отказывает до мутации; новый
recovery UI не служит основанием считать незакрытые гарантии доказанными.

### D5. Аварийное окно и возврат управления

**Продуктовое решение 2026-10-15:** пользователь поручил выбрать наиболее качественный
вариант. Выбран приоритет сохранности данных: уже удержанный ввод сохраняется в RAM,
новые нажатия в проблемном приложении временно и явно блокируются; остальные программы
продолжают работать. Отклонённый новый ввод придётся повторить. Автоматического replay
сохранённой очереди нет. Это принятое поведение, но не доказательство готовности
системного адаптера: включение по-прежнему требует допуска и живой приёмки.

При recoveryUnconfirmed защищённая очередь передаётся RAM-владельцу и активируется
ограниченный handover к собственному окну. Пока gate исправен, проблемный процесс
не получает новый изменяющий клавиатурный ввод; остальные приложения и переключение
между ними должны работать. Программа явно сообщает, что ввод в проблемное окно
приостановлен. Неудачная активация окна не разрешает replay в старую цель.

Первоначально показываются причина, приложение и счётчики. Содержимое раскрывается
только явным действием. Текстовая проекция содержит только доказуемые фрагменты;
shortcuts, навигация и мышь остаются отдельными упорядоченными записями. Произвольная
последовательность событий не выдаётся за итоговую восстановленную строку.
Фрагмент означает точный валидный Unicode payload конкретного события, а не
подтверждение вставки фреймворком. Reader запускается лишь после принятого reveal
intent текущей записи, не делает TIS/AX/clipboard/IO и не переиспользует исправляющий
UTF-16 decoder детектора слов. Некорректные surrogate и неоднозначные команды
остаются отдельными unresolved-записями, без догадок и вычисления конечного текста.
Пользователь может редактировать локальную копию и вручную копировать её стандартной
командой. Handover не меняет clipboard, не пишет файл и не исполняет сохранённые команды.

После частичного или полного локального ordinary post recovery сохраняет metadata
attempted/returned отдельно от payload. Если хотя бы один post был начат, окно уже
до раскрытия показывает: «Часть сохранённого ввода могла уже попасть в приложение.
Перед копированием проверьте исходный текст.» Скрытие и повторное открытие не теряют
предупреждение. Оно не означает подтверждённую доставку; отсутствие attempts также
не доказывает неизменность редактора. Старые записи без ordinary metadata выглядят
по-прежнему. Обнуление текущих RAM-счётчиков после удаления не переписывает историю
попыток доставки; metadata не создаёт payload views и не читает события.

Изменение защиты, причины или счётчиков той же записи обновляет только metadata
поддерево окна. Оно не активирует скрытое окно, не создаёт новый reveal, не меняет
revision/черновик/editor token и не отменяет уже открытое bound подтверждение.
Обновление с чужим record UUID отвергается. Payload/editor views остаются прежними;
повторный show не используется как механизм обновления статуса OFF/TCC/gate-loss.

Закрытие окна только скрывает его; запись остаётся доступной из меню. Удаление
требует явного подтверждения. Автоматического raw replay нет ни в прежний, ни
в новый адресат. Возвращение AX или таймер не закрывают recovery самостоятельно.
Условия снятия quarantine отделены от удаления записи: сначала подтверждённый
безопасный контекст/завершение старых команд либо явное прекращение защиты пользователем.
Последнее не объявляется системным подтверждением исправленной каретки.

#### D5.1. Общий интерфейс подтверждения выхода

Окно восстановления и applicationShouldTerminate используют один адаптер жизненного
цикла поверх уже существующих requestQuit/decideQuit. При pending recovery выход
приостанавливается: пользователь выбирает остаться либо явно завершить с удалением
RAM-записи и черновиков. Отмена сохраняет исходные события и отредактированные копии;
закрытие/скрытие окна не считается подтверждением. Повторный запрос не создаёт
второе окно или повторное удаление. Пока очередь передаётся, выход остаётся pending;
адаптер не подменяет handoverRequired разрешением на завершение.

Для приёмки 5.1 адаптер сначала подключается к существующему двухпроцессному
диагностическому режиму с настоящей захваченной очередью. При явном подтверждении
проверка завершает собственный child, затем driver, затем родительское приложение.
Подтверждение удаления не означает исправленную каретку или отмену pending команд.
Production factory остаётся недоступной до системного допуска; полное подключение
OFF/TCC/Secure Input/quit в обычный runtime относится к незакрытой 3.2.

Диагностические timeout/abort с уже принятой очередью проходят тот же интерфейс:
при необходимости выполняется storage-only retirement, затем запрашивается решение.
После отмены данные остаются доступны; автоматический deadline не служит скрытым
удалением. Отказ до мутации без принятых событий не требует фиктивной recovery-записи.

### D6. Резервирование и пределы

Первая версия допускает одну pending-запись. До первого удержания резервируются 256 событий
и 64 KiB логического UTF-16 payload. Это лимиты сохраняемого содержимого, не обещание
точного RSS для непрозрачных CoreGraphics объектов. Payload/metadata не публикуются
в логах; проверка лимита не должна требовать чтения закрытого поля редактора.

До исчерпания reservation система прекращает допуск в текущую транзакцию и
переходит в recovery через уже подготовленный gate. Удержанные события не вытесняются;
нет TTL и молчаливого discard. Новые события после handover не расширяют старую очередь.
Поведение отклонённого нового ввода в проблемное приложение должно быть видимым.
Если адаптер не может обеспечить этот переход без потери уже принятого ввода и
неограниченного глобального hold, prearm обязан отказать до selection.
Проверка ёмкости выполняется до принятия события, а не после append. Для события,
которое пересекает предел (включая первое слишком большое событие), необходим явный
атомарный исход: оно не может пройти прежнему получателю впереди удержанного префикса
или незаметно исчезнуть как якобы сохранённое. Новая пара Down/Up не разделяется между
обычной доставкой и recovery без принятого контракта балансировки. Отказ нового ввода
следует принятому решению D5; неподтверждённый системный prearm остаётся unavailable.
400 мс остаются пределом разрешения на дальнейшую мутацию; это не разрешение
автоматически выпустить очередь в неподтверждённое выделение.

### D7. Разрешения и завершение

При Secure Input/защищённом поле новые данные не накапливаются и не читаются.
Уже принятая очередь сохраняется только в RAM. Потеря gate/TCC запрещает новые
отправки, не превращает неизвестный cleanup в безопасный и не вызывает replay.
Дальнейшие физические события, которые macOS больше не даёт перехватывать,
не объявляются контролируемыми приложением; ошибка показывается пользователю.

OFF немедленно прекращает перехват/конвертации, сохраняя доступ к RAM recovery
и предупреждению о неподтверждённой цели. Graceful quit при pending не должен
незаметно удалить или replay очередь: пользователь выбирает остаться либо
явно завершить с удалением. Crash/force kill не переживаются RAM-хранилищем;
скрытый дисковый журнал ради такой гарантии не вводится.

Остановка tap не отменяет уже отправленные собственные пакеты. Перед снятием gate
нужно закрыть их admission либо доказать завершение; один вызов disable не выполняет
это условие. Отдельный фильтр только собственных пакетов после OFF является кандидатом,
а не принятым исключением из прекращения перехвата. Пока такой lifecycle-контракт
не проверен, адаптер не получает prearm. Graceful quit учитывает и пустую очередь
с опасной целью/незакрытой отправкой; явное удаление RAM не доказывает отмену AX RPC.

Own-PID disable probe подтвердил этот предел: stale keyUp закрытого поколения прошёл
в NSApplication.nextEvent, пока head tap был выключен; до выключения и после возврата
аналогичные события блокировались. Пять собственных keyUp, 223 мс, оба tap очищены,
без окон/активации. `.build/recovery-receiver-disable-probe-result.json` содержит
`safetyPassed=false` и `recoveryGateAccepted=false`. Это контролируемый fail-open,
а не проверка TCC или автоматического восстановления.

#### D7.1. Чистый кандидат gate и реестр собственных отправок

Следующий проверяемый кандидат состоит из чистых `RecipientGateState` и
`NativeDispatchRegistry`. Он не создаёт tap и не объявляет production admission.
Реестр ограничен 256 записями; это отдельный предел, не замена квот удержанного ввода.
Каждая собственная отправка связана с непереиспользуемыми token/marker, поколением,
экземпляром целевого процесса и парой Down/Up. Нет скрытого вытеснения при заполнении:
отсутствие reservation запрещает новую отправку до собственной мутации.

`prepared`, `submitted`, `admitted` и `prevented` учитываются раздельно. Закрытие
поколения не является ACK или ретроактивной отменой; уже admitted пакет остаётся
незакрытым до отдельного доказательства завершения. `prevented` требует основания
предотвращения до admission, а не только таймера или смены состояния. Paired Up
допускается однократно только после фактического допуска соответствующего Down;
он не разрешает новый Down и не переадресуется другому экземпляру процесса.

Защитное состояние должно быть установлено до selection. В нём worker отклоняет
не сопоставленный с разрешённой собственной отправкой target Down и инициирует
handover; отклонённый новый ввод не выдаётся за уже сохранённую очередь. Потеря gate
защёлкивает lost-состояние: поздний callback или возврат условий не оживляет старый
допуск. Чистые тесты этих переходов не подтверждают системную доставку или блокировку.

Пока это только тестовый кандидат: production factory остаётся unavailable.
Разрешение обычного replay и отдельное завершение только собственных пакетов после
OFF не приняты; существующие ограничения 4.2, lifecycle и живой приёмки сохраняются.

#### D7.2. Системный probe с тем же реестром

DEBUG-мост `RecoveryRecipientProbeBridge` связывает настоящий ledger и
`RecipientGateState` с существующим own-PID worker и собственным NSTextView.
Отдельный режим `--recovery-recipient-probe` сохраняет прежние исторические probes.
До чтения shape callback сверяет sender PID и точный зарезервированный marker;
marker проходит roundtrip до post и на head/tail. Подготовка пары не создаёт
submission: token регистрируется непосредственно перед post, adapterReturned — после.
Worker передаёт только ограниченные метаданные admission/реального отклонения;
MainActor переносит их в ledger. Ни tail, ни окно наблюдения не создают receiverCompleted.
Сценарий disable отправляет пару под worker barrier, затем закрывает поколение,
выключает head и снимает barrier. Полученная доставка остаётся fail-open ограничением,
а не положительной приёмкой. Production factory по-прежнему unavailable.

Наблюдение v2 уточнило предел disable: уже queued callback может исполниться после
выключения head. В проверенной паре Down был заблокирован этим callback, а Up прошёл
в tail/NSTextView; текст не изменился. Требование bypass обеих клавиш было ошибочной
гипотезой первого probe. V2 проверяет точное разбиение отправленной пары, порядок
tail==receiver и эффект фактически полученного Down. Lost сохраняет ledger
Prevented=0, Unknown=1, Unresolved=2; это не ACK или разрешение replay.
Локаторы обоих протоколов и SHA сохранены в acceptance; полный допуск 4.2 остаётся открытым.

## Статус компонентной реализации — 2026-10-15

Исторический локальный срез 686 тестов расширен двумя final-validation регрессиями:
компонентный checkpoint 688 прошёл без failures/skipped в 23:04:21 МСК.
После checkpoint 616 добавлены 21 проверка Unicode/safety, 21 projection/reader,
12 reveal, 16 UI session и две проверки final external isValid. Будущие candidate
gate/wiring-файлы не включены в этот результат. Opt-in Unicode требует bound receiver
contract и отдельно учитывает невыпущенный Up; обычный runtime ещё не создаёт ledger
и не передаёт очередь RecoveryCoordinator. Default Unicode не включён.

DEBUG preview с фиксированной RAM-очередью и fake gate подтвердил metadata-first,
редактирование копии, ручное копирование, hide/reopen, отмену и подтверждение удаления.
Повторный прогон увидел удалённый payload и недоступность reveal/Delete, но выявил
устаревшие UI-счётчики. Исправление принято следующим live-прогоном: после удаления
показаны нулевые счётчики, Delete недоступен, reveal/payload отсутствуют. Найденная
review гонка final external isValid после permitsReceipt в clipboard/Unicode покрыта
двумя новыми регрессиями в срезе 688. Timeout 120 секунд относится только к preview, не является
production TTL и не проверяет graceful quit реальной очереди. Полный протокол и SHA
кандидата — в `docs/acceptance-2026-10-15.md`. Системный gate и production P1 остаются открытыми.

#### D7.3. Два собственных процесса и настоящий capture handover

Следующая интеграция использует тот же подписанный bundle: отдельный DEBUG receiver
с единственным фиксированным NSTextView и sender с существующим recovery-окном.
Ограниченные inherited pipes передают только nonce, готовность, шаги, счётчики и
точные booleans текста/каретки. Payload событий и содержимое редактора не передаются.
Sender сверяет PID и birth независимо от pipe; смерть/EOF/новый процесс закрывают
старый scope без rearm/replay. Новые разрешения TCC не запрашиваются.

Переиспользуются RecipientGateState, worker, RecoveryOperation/CapturePort,
RecoveryCoordinator и RecoveryWindowController. Sender identity отделяется от
target identity; все части операции используют один ledger. Принятый префикс
должен пройти настоящий callback и CapturePort, а не populate готового batch.
При handover capture attachment снимается, target quarantine сохраняется,
а recovery-редактор другого PID принимает контрольный ввод. Известный отрицательный
пакет при утечке обязан попасть в обычный NSTextView dispatch: receiver не маскирует
отказ gate собственной фильтрацией. До полноценной системной и внешней приёмки
production factory, обычный replay permit и фактическое runtime wiring не включаются.

Живой опыт 2026-10-16 после разблокировки показал, что `postToPid` обходит общий
session tap: captured=0, per-PID head отклонил prefix Down, а prefix Up дошёл до
receiver без изменения текста. Для отдельного следующего кандидата capture
подключается непосредственно к per-PID head. Транспорт выбирается до selection;
одновременного захвата через два tap нет. Это исправление диагностического
маршрута, не разрешение production gate и не изменение критериев его допуска.

Head вызывает тот же CaptureRouter/Port до registry/quarantine и вне driver lock,
чтобы не создавать цикл capture→admission→driver. Только `.suppress` возвращает nil;
остальные события продолжают прежнюю проверку gate. Session сильно владеет router,
driver хранит слабую ссылку и неизменяемые fixture headers: после detach/освобождения
endpoint старые prefix Down/Up блокируются без чтения payload. Binding одноразовый,
связан с тем же bridge и endpoint UUID. Lease, лимиты и protected detach не ослабляются.
Expiry, stale callbacks, loss и конкуренция close/capture проверяются отдельно;
отключение native tap по-прежнему может обойти callback и остаётся ограничением.

Диагностический baseline того же child отдельно проверяет обычный приём известной
пары без gate: точные текст/каретка сверяются внутри receiver, наружу выходят booleans.
Это проверка чувствительности наблюдателя, а не конвертация или safety PASS.

#### D7.4. Сохранение RAM после потери защиты до adopt

Защита целевого приложения и передача уже сохранённой очереди в RAM — разные
свойства. При утрате gate прежний protected detach остаётся недоступен, но данные
должны стать доступными через отдельный storage-only переход после локального
прекращения capture. Этот переход не является новым admission, отменой native/AX
отправки, renderer ACK, снятием key debt или разрешением replay.

Router выдаёт ticket каждому вошедшему capture и учитывает его до завершения
чтения длины, копирования и счётчиков. Retirement необратимо закрывает новые tickets,
сохраняет metadata tombstone и инвалидирует старый read-generation. Port отдельно
закрывает admission и получает seal. Ожидание уже вошедших callbacks не выполняется
под router/port/admission/driver lock и не блокирует MainActor: pending сохраняет
app-owned очередь, следующий ограниченный шаг может повторить проверку.

Только retired router с нулём активных tickets и связанным seal может выпустить
неподделываемый одноразовый `RecoveryRetiredCaptureProof`. Он связан с полным scope
(operation/process instance/hold/tap UUID), retirement identity и конкретным seal.
Port проверяет proof и атомарно detach только для хранения, без вызова системного
gate и без отправки событий. Повторный/чужой proof ничего не изымает; обычный
защищённый путь и первоначальная готовность до selection не ослабляются.

RecoveryOperation завершает исход только как recoveryRequired и передаёт очередь
прежнему единственному Coordinator. UI показывает unavailable или interceptionOff;
возврат прав не восстанавливает old lease/replay. Pending submissions остаются
unknown. Disable-return и EOF не считаются доказательством локального quiescence
или смерти процесса. При невозможности закончить retirement очередь остаётся
у прежнего владельца, без выдуманной успешной передачи.

Проверки: барьеры перед/после чтения длины и append, гонки capture/retire, поздний
callback, stale/foreign/reused proof, пустая опасная очередь и сохранность unknown/debt.
Живой диагностический отказ до adopt должен показать сохранённый префикс в UI
без replay при недоступной защите; production и полная 4.2 матрица остаются закрытыми
до собственной приёмки.

В безопасном двухпроцессном fault-опыте выключается только собственный driver:
до selection проверяется отказ допуска без команд, после capture — storage-only
handover уже принятой пары. После потери защиты новые клавиши не отправляются;
child отвечает только на metadata snapshot/quit. Это реальная остановка test tap,
не имитация отзыва TCC и не проверка защищённости дальнейшего физического ввода.

#### D7.5. Расширенная событийная матрица системного кандидата

До включения первого AX-профиля DEBUG per-PID gate проверяется на modifier changes,
shortcut keyDown/keyUp и изменяющих mouse events в собственном дочернем NSTextView.
Worker подписывается на эти типы явно; для каждого типа различаются head decision,
tail ingress и реальный AppKit dispatch. Все журналы ограничены метаданными,
тестовый режим не читает произвольный Unicode payload и не снимает lost latch.

Для AX-профиля собственные native modifier/chord mutation не требуются: исходная
матрица проверяет подавление чужого вводимого shortcut и баланс release. Допуск
собственных native команд для clipboard/Unicode остаётся отдельной частью 4.2.
Mouse проверяется через обычное UI-управление только после положительного control,
подтвердившего реальные NSEvent/CGEvent; AXPress без таких событий не считается
проверкой mouse tap. Синтетический mouse driver этим планом не разрешается.

Перед activation проверяются отпущенные кнопки мыши: gate не должен перехватывать
завершение уже начатого AppKit tracking loop. В mouse mask также входит scrollWheel;
mouseMoved не блокируется. Modifier release не добавляет ни одного бита относительно
последнего действительно пропущенного состояния. Неоднозначное сочетание левого и
правого модификаторов блокируется до однозначного clearing-state, без фиктивного ACK.

Проверяются healthy control, protected phase, close/loss и влияние на другой процесс.
Без control и полного живого протокола новые модельные тесты не закрывают 4.2.
Это продолжение существующей обязательной матрицы, не включение production factory.

Контроли v1–v3 доставили известный Cmd+A с правильными флагами/символом, но без
эффекта выделения в child; это не положительная проверка shortcut. Следующий стенд
проверяет отдельный вложенный fixture bundle с собственной identity и обычным AppKit
activation policy. Он запускает только nonce-bound receiver, не обычный AppDelegate,
не запрашивает AX/Input Monitoring/Post permissions и не устанавливает tap.
Перехват и клавиатурный драйвер остаются в основном подписанном приложении.
Раздельные identity должны также дать CUA однозначный выбор тестового окна; это
гипотеза стенда, требующая control, а не доказанное объяснение предыдущего результата.

Диагностика failed control дополняется только фиксированными Bool: editable/selectable,
цель обычного Select All и enabled menu item после обычного menu.update. Действие
Select All вручную не вызывается. Последующее A/B сравнивает принудительный Unicode
командного CGEvent с нативным Unicode, сохраняя остальные свойства пакетов/маршрут.

Для mouse control после положительного AppKit click устанавливается тот же per-PID
head/tail driver в prepared phase без activateProtection. Он пропускает события и
считает их типы; это позволяет отличать реальный проход через tap от локальной
AppKit доставки, включая Up/drag, которые NSTextView может забрать внутри tracking loop.

Фокус проверяется отдельно от адресного ввода CUA: явные кнопки стенда активируют
только собственный parent либо проверенный PID+birth child через NSApplication/NSRunningApplication.
В протокол попадают лишь Bool frontmost/active; возврат activate сам по себе не считается
успешной сменой фокуса. Поля второго процесса не связаны с capture целевого приёмника.

Для диагностики не сработавшего Cmd+A первый exact known-parent keyDown дополнительно
даёт только булевы признаки Command, characters=="a" и charactersIgnoringModifiers=="a".
Строки не сохраняются и не выводятся; чужие события до этих чтений отбрасываются.
Обычный Select All проходит стандартное Application/Edit menu и responder chain;
ручной вызов selectAll из keyDown не допускается как замена проверяемого поведения.

#### D7.6. Собственный child и настоящий ordinary proxy flush

Отдельный DEBUG-режим использует существующий подписанный receiver helper и тот же
bounded nonce/sequence IPC с четырьмя фиксированными marker. Configure/selectFixture
выполняются до arm и являются только подготовкой fixture; журнал операции не содержит
собственных изменений редактора. App заранее удерживает diagnostic facade и скрытое
recovery-окно. Facade владеет одним ledger/coordinator/router/operation/flush; reservation
использует permitsCaptureReservation, но capture допускается только после atomic worker arm.
Setup ограничен 10 секундами, исходная hold lease — 400 мс без продления.

Control без системного gate отправляет только challengeRelease: keyUp 0, пустые Unicode
и flags. Receiver должен наблюдать этот Up обычным AppKit dispatch и подтвердить
неизменные fixture/selection/changeCount. Отдельный ordinaryWakeReleaseObserved
проверяет фактический NSEvent keyUp, known label, keyCode 0 и нейтральные flags без
чтения Unicode; один label не считается доказательством типа. Этот опыт проверяет выбранный wake-control,
не renderer ACK и не допустимость преобразования произвольного редактора.

Positive удерживает фиксированную пару kept Down/Up: 2 события, 16 UTF-16 байт.
После no-owned-mutation decision один ordinary claim запускает реальный
CGEventTapPostEvent(proxy) внутри marker callback. Receiver подтверждает exact kept,
caret 4, одно изменение и prefixDown/prefixRelease. Затем отдельная пара challengeDown
с фиксированным x и повторным prefixRelease проверяет новый ordinary input: exact keptx,
caret 5, два изменения и четыре полученных label. challengeRelease остаётся wake tombstone
 и не используется для отпускания этой пары. IPC возвращает fixed booleans,
а также wake-observation bool, но не текст, raw events или команды с произвольным payload.
В положительном flush wake-observation остаётся false: control не должен достигнуть child.

Negative использует тот же настоящий захваченный prefix, но postWake после claim явно
отказывает без реального wake post. После локального quiescence полный оригинал принимает
Coordinator с тем же ordinary claim. Recovery UI по умолчанию показывает только metadata;
раскрытие и quit используют уже принятые explicit intents. Ошибки/timeout после capture
не удаляют RAM: сначала handover, затем решение пользователя. При завершении child получает
EOF и завершается до остановки driver; ни один ошибочный путь не повторяет native delivery.

Перед каждым fixture post проверяются собственные PID+birth, фокус child и modifiers;
clipboard и AX не используются. Отчёты содержат только counts/bools/enum и fixture-only
границы. Source/hash manifest и живые запуски выполняются отдельно; production factory
и глобальный processing lease этим диагностическим режимом не включаются.

### D7.8. Собственный TextEdit: выделение, потеря readback и удержанный ввод

После отдельного healthy control DEBUG pilot допускает явный дополнительный флаг
`--recovery-textedit-fault=missing-after-selection` только вместе с обязательным
`--recovery-textedit-pilot=/absolute/own-file.txt`. Неверный, повторный либо отдельный
fault-флаг завершает запуск без legacy fallback; обычный и Release runtime его не используют.
Проверка file URL, профиль, ledger, prearm, native capture и 400 мс остаются прежними.

Отдельный wrapper выполняет один настоящий подготовленный selection setter с тем же
submission token, затем запрещает дополнительные setters. До первого ожидания свежий
снимок разрешён. Первый waitForUpdate проверяет фактический диапазон выделения и
асинхронно ждёт подтверждения prefix по metadata существующего capture: не менее двух
событий, двух чтений длины Unicode и ненулевого числа UTF-16 байт. Ожидание ограничено
минимумом из 100 мс и остатка исходной lease; MainActor не блокируется. Разрешённый
внешний HID helper с проверкой заголовка отправляет double Shift и фиксированный prefix
одним заранее подготовленным batch. Wrapper не создаёт и не отправляет события сам.

После ожидания поставщик snapshot постоянно возвращает nil, не читая payload.
При отсутствии prefix, смене контекста, отмене либо deadline опыт считается INCONCLUSIVE,
а не успешной проверкой P1. При совпавших условиях это инъекция missing readback после
реальной AX-мутации и реального capture, а не утверждение о естественном сбое macOS.
Приёмка требует исходный текст с опасным выделением, ноль text/повторных selection writes,
отсутствие TIS/receipt/replay, передачу исходного prefix в RAM и блокировку последующего
ввода целевому приложению. Reveal, hide/reopen и quit-cancel проверяют ту же запись.
Отчёт содержит только enum, счётчики и booleans; clipboard, payload-журналы и файлы с
удержанным вводом не используются. Сам wrapper и компонентные тесты не закрывают 4.2.

### D7.9. Диагностические Secure Input и отключение собственного tap

Отдельный DEBUG CLI `--recovery-system-fault=` принимает только control,
secure-before-arm, secure-after-capture, head-before-arm, head-after-capture
и tail-after-capture. Он использует существующий подписанный own-child, bounded
nonce/sequence IPC и четыре заранее выделенные fixture-метки. Новый Core facade
связывает реальные RecoveryIsolationSession/RecipientTapDriver; capture принимает
только известный prefix от собственного sender PID. Произвольный пользовательский
ввод, AX-конвертер и обычный production runtime этим стендом не подключаются.

Child выполняет EnableSecureEventInput, DisableSecureEventInput и IsSecureEventInputEnabled
только на MainActor. При уже включённом глобальном режиме Enable не вызывается.
Один успешный собственный Enable имеет один соответствующий Disable; повторный start
не наращивает счётчик. Собственный режим снимается при явном stop, inactivity, EOF,
abort и двухсекундном TTL. Ошибка Disable не объявляется успешной балансировкой.
Parent имеет отдельный ограниченный watchdog собственного child; при cleanup
не затрагиваются чужие процессы или чужой Secure Input enable count.
Watchdog вооружается до отправки Enable. Неуспешная отправка не снимает страховку
до подтверждённого собственного Disable либо завершения child.

Команды secureInputOn/secureInputOff не содержат payload. Ответ secure_input и
optional secure metadata содержат только Bool и ограниченные счётчики 0/1; отсутствие
полей в прежнем протоколе не меняет прежние режимы. Secure metadata не добавляется к
matrix frame. Никаких паролей, clipboard, AX-чтения, payload-журналов или CG mouse.

Control подтверждает обычную доставку фиксированной пары в собственное поле.
Before-arm faults отказывают до capture/мутации: Secure Input отказ является явным
diagnostic preflight по ответу child, а не принятым production guard. Mid-hold faults
начинаются только после фактического capture 2 событий/16 UTF-16 bytes. Затем scope
необратимо закрывается, полный prefix передаётся storage-only, а отдельная поздняя
fixture-пара измеряет дальнейшее поведение доставки. Это тестовые posts, не replay
удержанного prefix. Они считаются отдельно; отсутствие callback не является ACK.
Оба пакета готовятся до первого Down. Если после начатого Down обычный Up не начат,
defer допускает одну попытку только подготовленного Up в исходный PID+birth, без
требования прежнего foreground. При потере identity или формы Up остаётся явный
unposted debt. Любая неполная обычная пара остаётся INCONCLUSIVE даже после balancing
Up; повторного Down, смены адресата и автоматического retry нет.
Начало quit/timeout необратимо закрывает diagnostic forward progress до ожидания
retention. После любого await start/disable/retire и после secure callback этот
допуск проверяется заново. Отмена quit не возобновляет старые continuation; разрешены
лишь сохранение/cleanup и описанный выше balancing Up исходному процессу.

Tap-disable выполняется только для собственного head либо tail на worker через
enqueue: sticky local loss, фактический tapEnable(false), затем isEnabled/обычный
health readback. Возврат disable не доказывает отмену queued packets или предотвращение
admission. Автоматического rearm и повторной отправки нет. Secure/off/tap-loss не
удаляют принятую RAM-запись; её раскрытие и удаление/quit используют прежний явный UI.

Отчёт всегда помечен fixture-only, productionEnabled=false и privacyGuardAccepted=false.
Он разделяет фактические наблюдения ОС, diagnostic refusal и непроверенный будущий
production guard. Cached clear не получает свойства instantaneous ACK, произвольный
TTL cache не вводится. Без отдельного guard и полной системной приёмки 4.2 не закрывается.

### D7.10. Разделение адресного и глобального HID diagnostic route

D7.9 показал доставку late postToPid после Secure Input/head loss; этот результат
не переносится на глобальный путь. Следующий own-child опыт добавляет явный DEBUG
route `pid|hid`, по умолчанию pid. Оба пакета готовятся до Down, каждый обычный post
проверяет тот же живой child PID+birth и настоящий foreground; при смене цели новых
Down нет. Balancing Up всегда адресуется исходному process instance, даже при HID
route, и не публикуется глобально в новое приложение. Отказ/частичная пара остаётся
inconclusive. Malformed/дублированный route и route без mode завершают запуск до App.

Первым идёт HID control с фактическим receiver text/selection, затем Secure Input
до/после capture и tap-loss. Маршрут записывается в metadata. Synthetic global HID
не объявляется физической клавиатурой, renderer ACK или достаточным privacy admission.
Собственные TTL/Enable/Disable/watchdog и сохранение RAM остаются прежними.

### D7.11. Окно обнаружения Secure Input

Отдельный DEBUG `secure-capture-window` вооружает candidate без prefix, включает
Secure Input только в собственном child и после подтверждения enabled/owned отправляет
ровно одну фиксированную пару. До наблюдения результата не вызывается искусственный
`observeSecureInput`: проверяется именно защита самого системного маршрута.
Сравниваются только metadata capture и известного fixture-получателя. Два события/
16 байт, захваченные в этом интервале, означают обнаруженную проблему приватности,
а не успешный допуск. Нулевой capture принимается наблюдением только при фактической
доставке той же пары child; отсутствие обеих доставок или частичная пара — inconclusive.

После наблюдения capture закрывается, собственные события сохраняются в RAM, Enable
балансируется тем же Disable/TTL/watchdog. Нет неизвестного текста, payload logging,
новых разрешений или production включения. Synthetic HID не заменяет физическую
клавиатуру. Подтверждённый захват запрещает production admission до устранения причины.

Для исключения ложного «не захвачено» после expiry diagnostic явно проверяет
действующие capture port/admission и native protection до post и после ответа child.
Истёкший/закрытый lease не принимается даже при нулевых счётчиках. Обе проверки
пишутся как metadata; они не регистрируют own command и не читают payload.

## Risks / Trade-offs

- Отказ внешнего API после submission → неизвестный исход и recovery, а не повторная мутация.
- Gate доступен только номинально → отдельные системные и живые проверки; до них профиль не включать.
- Ошибка фокуса/recipient → запрет перенаправления raw input; не заменять доказательство snapshot профилем приложения.
- Private input → по умолчанию скрытое содержимое, запрет новых чтений/capture при protected/unknown контексте.
- Пользователь выключил защиту или отозвал права → сохранить уже принятое и честно сообщить предел дальнейшего контроля.
- Чрезмерный ввод/непредставимые команды → reservation и видимый отказ нового допуска; не обещать смысловую реконструкцию.

## Migration Plan

1. Ввести чистые типы disposition/ownership и регрессии воспроизводимых отказов.
2. Перевести все движки на явный журнал mutation/cleanup и передать исход наверх.
3. Реализовать detach/lifecycle и RAM-хранилище без активации нового системного профиля.
4. Проверить system gate отдельными безопасными probes; только затем связать prearm и recovery UI.
5. Пройти fault/continuation матрицу в собственных документах. Не переносить результаты
   прежних бинарников и happy-path наблюдений на постоянный отказ.
6. Собрать, проверить CI и восстановить исходные настройки. При rollback неподтверждённый
   профиль запрещается до мутации; возврат к известному unconditional replay недопустим.
