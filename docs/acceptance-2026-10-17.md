# Восстановление ввода: компоненты и клавиатурная матрица — 2026-10-17

`fix-input-recovery` остаётся открытым: **4/14 задач**. Новые владельцы очереди,
processing lease и системный transport ещё не включены в обычный LSwitch.
Ни число тестов, ни отдельный положительный контроль не закрывают production wiring.

## Проверенный компонентный срез

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

Открыты: положительный mouse control, реальная обычная передача очереди, focus/order,
TCC/Secure Input, lifecycle рабочего приложения и включение принятых профилей.
Ни stage0/1/2, ни bridge, ни задачи 2–4/6 этого change этим срезом не закрываются.
