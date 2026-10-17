# Восстановление ввода: компоненты и клавиатурная матрица — 2026-10-17

`fix-input-recovery` остаётся открытым: **4/14 задач**. Новые владельцы очереди,
processing lease и системный transport ещё не включены в обычный LSwitch.
Ни число тестов, ни отдельный положительный контроль не закрывают production wiring.

## Проверенный компонентный срез

Актуальный срез завершил `make build`, **994 теста без failures/skipped** (13:48:29 МСК)
и **7 protocol-групп**. Логи `.build/input-recovery-native-{build,test,protocol}.log`;
source manifest `.build/recovery-ordinary-v1-manifest.json`. Включены атомарное
вооружение capture, настоящий proxy flush с единственным владельцем, удержание после
частичного отказа, предупреждение о возможной доставке и собственный D7.6 probe.
Новые UI/native проверки и production wiring в число unit-проверок не включаются.

Срез `a1bbd53` прошёл build/test/protocol в CI, но
[SwiftLint нашёл 9 нарушений](https://github.com/cramen/LSwitch/actions/runs/39022915562).
Все девять исправлены в текущих исходниках; итог следующего CI ещё требуется проверить.

Срез `d386dcb` снова прошёл build/test/protocol; его
[CI](https://github.com/cramen/LSwitch/actions/runs/39026409766) нашёл только complexity=12
в диагностическом retention. Выделен отдельный ordinary-retention helper без изменения
порядка владения. Изолированный срез повторил build/994 теста/7 protocol-групп;
лог `.build/recovery-994-lint-check.log`.

Общий `make build` / `make test` завершился 12:44:40 МСК: **954 теста, 0 failures,
0 skipped**. Дополнительный `make check-recovery-protocol` — 6 групп без UI,
отправки событий и clipboard. Логи `.build/input-recovery-custody-final-{build,test,protocol}.log`.

Изолированный точный срез для CI повторил build, 954 теста без ошибок/пропусков
и 6 protocol-групп в 12:50:38 МСК. Source hashes:
`.build/recovery-954-checkpoint-manifest.json`; логи
`.build/recovery-954-checkpoint-{build,test,protocol}.log`.
Следующая незавершённая интеграция native worker в него не включена.

- AX B различает настоящий fault и проверенное отсутствие слова: ручной no-op
  требует второго точного снимка и нулевого журнала мутаций, не меняет TIS и не даёт receipt/звук.
- Tracked Converter принимает очередь отдельно от окончания локальной доставки;
  внешний owner остаётся занят, пока transport не выдаст терминальный результат.
  Отмена не создаёт второй claim и не объявляет завершение неоконченного post.
- Processing lease приостанавливает логическую обработку, сохраняя исходную native
  доставку. Ограниченный хвост передаётся после обработки outcome. Исправлены
  реальная подписка на scrollWheel и гонка между begin и arm; исходный CGEvent не меняется.
- Ordinary custody хранит оригиналы и отправляет только отдельные копии. После
  частичного отказа coordinator получает весь оригинал с прежним ordinary claim
  и числом возможных отправок. Proof выдаётся только после локального quiescence.
- Recipient capture использует scoped policy и квоты. Неизвестная статическая
  synthetic-метка не выдаётся за собственный token и не теряет чужое событие.
  Допуск мыши атомарен с callback; разные дополнительные кнопки учитываются раздельно.

Независимые review processing lease, custody, AX no-op, callback policy и диагностики — CLEAN.
Предыдущий `d3691c3` прошёл build/test, но его
[CI](https://github.com/cramen/LSwitch/actions/runs/38913517120) отклонил 5 нарушений SwiftLint.
Исправления входят в новый срез; это ещё не утверждение о результате его CI.

## Рабочий контроль shortcut

v1–v5 доставляли Cmd+A с правильными flags/characters, но не вызывали выделение.
Смена route на session, отдельная identity helper и обычное Application/Edit меню
сами по себе этого не исправили. Эти попытки не считаются успешным контролем shortcut.
v5 дополнительно подтвердил editable/selectable/targetIsEditor/menuEnabled=true.

Между v5 и v6 изменён только Unicode override командной клавиши: оставлен нативный
Unicode, как в рабочем KeyboardEmitter. CGEventSource остаётся private, route — recipient.
v6 штатно выделил весь текст; keyDown прошёл меню, не вызвав view.keyDown.
Это воспроизводит известное ограничение подмены Unicode командных событий.

| Срез | SHA-256 основного executable | SHA-256 receiver |
|---|---|---|
| v5 | `d53b6aceec32dd90a8f771914a185417142c7757164db038970de428bfd51717` | `6481ce1251e3d49725c63eea5af9807d5b335d9c86a84280dfc2a26c8c7ebd85` |
| v6 | `53545c7783e2b371e794bc565410909a13174d0ba7c8432f6f7d02f7fc0a32dc` | `de70b72cc352fbd566c060a2741466ce45ddf8875a88ae111bd754c7ea78756b` |

Точные manifests: `.build/recovery-event-matrix-v5-manifest.json` и `v6-manifest.json`.
Receiver — отдельный вложенный bundle `ru.cramen.lswitch.receiverprobe`; обычный
AppDelegate в нём не запускается. Проверка executable дала `receiver-only: true`.
Новых TCC-разрешений стенд не запрашивал.

На одном v6 выполнены четыре автоматических опыта:

| Режим | Наблюдение |
|---|---|
| control | Все 4 пакета дошли до AppKit, текст целиком выделен, текст не менялся. |
| protected | Cmd Down и A Down заблокированы; только KeyUp и очищающий modifier release дошли. Выделение не изменилось. |
| closed | То же разбиение пары после закрытия поколения; собственных мутаций нет. |
| lost | То же разбиение при логическом latch peerEOF. Head/tail tap оставались включены; это не реальный отзыв прав или остановка tap. |

Во всех четырёх опытах child exit=0, final reply/EOF/cleanup=true, переполнения нет.
Основной stderr пуст. Child сообщил 308 байт диагностического stderr: содержимое не
сохранялось, происхождение не классифицировано; нулевой child stderr не заявляется.
Протоколы: `.build/recovery-event-matrix-v6-{control,protected,closed,lost}.jsonl`.
В них `productionGateAccepted=false` и `rendererACK=false` намеренно остаются false.

## Границы проверки

Интерактивный v4 не дал приёмки мыши: CUA завершился длительным timeout, внешний
runner завершил собственные процессы по пределу 600 секунд и восстановил обычный
LSwitch. Финального graceful-протокола этого опыта нет; PASS не присваивается.
Локатор `.build/recovery-event-matrix-v4-ui-control.jsonl`.

Обычный bundle не заменялся, его SHA:
`7f52d970e38630d83ded9806d2ffecc15503060f9ebe4e9cf92837b32f67c61f`.
После автоматических опытов он восстановлен. PuntoSwitcher/Caramba не запускались.
CG mouse emitter сохранён отдельно как неподключённая заготовка; mouse posts не выполнялись.

## Мышь и настоящий системный фокус

v7 добавляет head/tail taps и в control: gate ещё не вооружён, события проходят без capture.
На одном бинарнике проверены left click/drag, right/middle click и scroll в собственном
NSTextView. В control все события дошли до tail; правый click открыл штатное меню,
закрытое его AX Cancel. В protected те же 12 mouse-событий заблокированы до tail.
NSTextView в protected не изменился; в другом собственном процессе обычный ввод прошёл.
Оба опыта завершены через UI, final reply/EOF/exit=0/cleanup подтверждены.
Правый и дополнительный drag живым опытом не проверены.

v8 подтвердил фактический цикл receiver → sender → receiver по frontmost/active/focused,
а не только по результату вызова activate. В sender прошёл тестовый `x`; после возврата
в receiver left Down/Up по-прежнему заблокированы, текст/selection не изменены.
Повторный опыт завершён штатно. Первая попытка v8 завершилась защитой fixture:
неизвестный CUA keyUp не входит в его whitelist; ей не присваивается приёмка.

| Срез | SHA-256 основного executable | SHA-256 receiver |
|---|---|---|
| v7 | `9d9287cd286d0530c6b3cd957edfab9b66455637efae9c3bc252c37c347a00a0` | `023d7e7b529bf2c31e1bc9f8a5b63c231f08a6963f63759f584fe0027db7184c` |
| v8 | `0b8af06a304d20980b5136dca4686c25ee4d5618b29b214dfef45ceb2af698ad` | `eecd8b55d9d69b41c7bcf4311073e496082ad51030f8d6967f48203ef094651e` |

Протоколы: `.build/recovery-event-matrix-v7-mouse-{control,protected}.jsonl`,
`.build/recovery-event-matrix-v8-focus-protected-repeat.jsonl`; manifests v7/v8.
Обычный LSwitch восстановлен, clipboard и CG mouse synthesis не использовались.

## Native ordinary: контроль, доставка и отказ

Срез `.build/recovery-ordinary-v1/LSwitch.app`:
main `32e901cc77d0c6c9e399cf74dd1daca0debfcb83d3ef8a7b4281b24779bb68f3`,
receiver `07730f13d53145aba8da364573d0e05619c38856829a24120d139326f3e98ddd`.
Manifest связывает 338 source-файлов с 994-test checkpoint.

- Control: standalone keyUp0 с пустым Unicode/flags дошёл до actual AppKit keyUp;
  text/selection/changeCount не изменились. Driver/capture не запускались.
- Flush: native capture удержал ровно 2 события / 16 UTF-16 bytes, затем один ordinary
  claim и один wake вызвали proxy posts обоих событий. Receiver получил `kept`, затем
  обычный следующий `x`: точное `keptx`, caret=5, changeCount=2 и порядок четырёх labels.
  Wake не дошёл до receiver. Это local dispatch + fixture observation, не renderer ACK.
- Retain: принудительный отказ postWake после claim дал 0 attempts/0 returned,
  те же 2 события/16 bytes в Coordinator. В receiver остались исходные text/selection,
  changeCount=0 и received=[]; автоматической повторной отправки нет.
  До раскрытия UI показывал только метаданные, затем известный тестовый фрагмент.
  Отмена quit сохранила запись, повторное раскрытие подтвердило её; финальный quit
  через подтверждение удалил только созданную тестовую RAM-запись.

Все три опыта: observed/finalReply/EOF/cleanup=true, childExit=0. Логи
`.build/recovery-ordinary-v1-{control,flush,retain}.jsonl`. Parent payload не логируется,
clipboard не используется; child stderr остаётся 308 неразобранных байт без содержимого.
После каждого опыта восстановлен обычный LSwitch. Production factory остаётся выключенной.

Открыты: интеграция с рабочим AX/clipboard/Unicode и логическим хвостом,
TCC/Secure Input, lifecycle рабочего приложения и включение принятых профилей.
Ни stage0/1/2, ни bridge, ни задачи 2–4/6 этого change этим срезом не закрываются.
