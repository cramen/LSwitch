# Подключение clipboard и Unicode к общему recovery runtime

Read-only разбор 18.10.2026. Это план следующей интеграции, а не подтверждение
системного допуска или выполненных задач 2.2/2.3. Текущий TextEdit AX pilot не
заменяет clipboard/native selection, DEBUG Unicode и матрицу остальных приложений.
Исходный предел 400 мс, точный undo и ограничения privacy сохраняются.

## Что уже реализовано

- `Sources/LSwitchCore/ClipboardMutationSafety.swift` и
  `ClipboardTransaction+Safety.swift` учитывают отправки, отдельный clipboard owner,
  структурированный cleanup и незакрытый долг отпускания клавиш.
- `Sources/LSwitchCore/UnicodeMutationSafety.swift` и
  `UnicodeTransaction+Safety.swift` применяют тот же журнал и отдельный cleanup
  к native selection и Unicode packet. Read boundaries, packet policy и inverse
  preflight остаются в `UnicodeReadBoundary.swift`, `UnicodeTextConverter.swift`
  и соответствующих transaction helpers.
- `ConversionRecoverySession.swift`, `ConversionRecoveryOwner.swift` и
  `TextEditRecoveryAdapter.swift` уже разделяют принятие ordinary ownership,
  локальное завершение transport и передачу полного оригинала в RAM recovery.
- `NativeDispatchRegistry.swift`, `RecipientGateState.swift` и
  `RecoveryRecipientProbeBridge.swift` содержат prepared/submitted/admitted/prevented,
  exact operation/process binding и одноразовые marker. Их системные probes не
  доказывают завершение редактирования сторонним приложением.

## Отсутствующая связь с настоящими отправками

`ClipboardEnvironment.swift` и `UnicodeEnvironment.swift` предоставляют optional
receiver contracts. В live-конфигурации сейчас нет системной реализации
`ClipboardReceiverContract.swift` / `UnicodeReceiverContract.swift` для завершения
каждой конкретной отправки. При ledger такой путь должен отказывать до мутации.

`KeyboardEmitter.swift` и `UnicodeEventEmitter.swift` помечают созданные события
общим `SyntheticEventMarker.magic` из `EventTap.swift`. Tracked hooks в
`KeyboardEmitter+Tracked.swift` и `ConversionDispatchHooks.swift` выдают ledger token
перед каждым post, но не связывают его с reservation в новом native registry.

Это существенная несовместимость с включённым recipient capture:
`RecipientTapCaptureEndpoint.swift` / `RecoveryCapturePolicy.swift` исключают
только exact own PID/marker, распознанный registry. Старый magic marker не является
такой reservation; собственные команды могут попасть в удерживаемый пользовательский
префикс. Обратная замена magic на новый marker также недостаточна:
`EventProcessingLeaseState.observe` сейчас узнаёт только старую общую synthetic метку.
Новые собственные native команды не должны стать logical tail либо запустить
повторную конвертацию после обычной доставки.

## Минимальный контракт sender на одну Session

1. Создавать sender одновременно с ledger и приёмником, связывая его с operation,
   поколением, PID и временем рождения процесса, выбранным editor context и registry.
   Один UUID контекста либо PID без birth не являются достаточной идентичностью.
   Session получает bound clipboard/Unicode engine, как сейчас bound AX engine;
   общий изменяемый «последний contract» между операциями не используется.
2. До первого post резервировать полную ограниченную последовательность пар
   Down/release с уникальными marker. Проверять roundtrip source PID, marker,
   event type, keyCode и flags до отправки. Подготовка пары сама не является submission.
   Ledger token создаётся и связывается с registry непосредственно перед post;
   отказ до отправки не должен выдумывать admitted/prevented/completed evidence.
3. В обоих путях capture классифицировать exact own header до чтения Unicode.
   Глобальный logical tap и per-PID endpoint используют один scoped namespace и
   PID/process binding. Чужой либо неизвестный marker не получает исключения.
   Закрытое поколение сохраняет tombstone; поздний пакет не становится обычным вводом.
4. Сохранять связь каждого release с соответствующим Down. После cancel/close
   допускается только баланс реально требуемого отпускания исходному экземпляру
   процесса; новый Down запрещён. Неотправленный/неподтверждённый Up остаётся debt.
   Потеря target/tap не разрешает перенос release в другой PID или повтор всей пары.
5. Queue ownership остаётся у app-owner до terminal transport result. После claim
   ошибка сохраняет тот же claim и полный оригинал; нет второго claim, retry, post
   из deinit либо автоматической записи payload в clipboard, файл или журнал.

Классификация marker подтверждает принадлежность к известной отправке, а не
аутентифицирует произвольный внешний источник и не доказывает renderer completion.
`preventedBeforeAdmission` возникает только после фактического отклонения callback,
а не по timer, close или потере tap. `admitted` и возврат post остаются отдельными фактами.

## Как принимать результат редактора

### Первый шаг: глобальная классификация собственных заголовков

Перед logical/legacy capture глобальный EventTap проверяет source Unix PID своего
процесса и реально зарезервированный serial общего NativeDispatchMarkers namespace.
Совпавшее событие пропускается без RawKeyEvent/Unicode чтения и без изменения activity.
Это только исключение собственной команды из логического ввода; фактическую доставку
по-прежнему решает per-PID gate. Проверка не означает admission/completion или
аутентификацию внешнего источника. Чужой PID, другой namespace, serial 0 и ещё не
зарезервированный serial сохраняют прежний путь. Allocator хранит monotonic high-water,
поэтому поздний собственный marker остаётся распознаваемым после закрытия registry
без сохранения payload или неограниченного списка прошлых Session. Другие allocator
namespaces не признаются production shared namespace автоматически.
DEBUG fixture-prefix получает отдельный namespace: он моделирует пользовательский
ввод и должен по-прежнему проходить capture. Смешение fixture и собственных команд
выявлено существующими callback-тестами; исключение не обходится изменением их ожиданий.

Этот шаг сам не подключает clipboard/Unicode sender и не разрешает их runtime.
Per-PID обработка старых own packets и их release debt остаётся отдельной обязанностью
bound sender/gate; глобальный pass-through не подменяет её.

Нынешние clipboard/Unicode evidence enums различают только `receiverCompleted`,
`preventedBeforeAdmission` и `unresolved`. Заполнение этих contracts событием
admission из gate дало бы ложное подтверждение. Перед healthy ordinary delivery
нужно отдельно принять один из двух вариантов:

- реальный контракт завершения конкретной отправки получателем;
- отдельный профиль `observedUnderProfile` с успешным API, точным свежим текстом,
  диапазоном, identity и sticky fault по D1.1, без переименования его в receiver ACK.

Профиль прямого AX TextEdit не распространяется автоматически на Paste, native
стрелки, AX menu actions или Unicode packets. Поздний AX RPC также нельзя считать
отменённым per-PID keyboard tap. До принятия конкретного механизма соответствующий
runtime остаётся отказом до мутации; модельный safe refusal не закрывает healthy acceptance.

## Следующая проверка задач 2.2 и 2.3

Для clipboard сначала соединить bound engine/sender с настоящим capture и повторить
обе регрессии `selection → missing state → Paste=0` с удержанным вводом в RAM.
Отдельно проверить исходные текст/RTF/PNG/files, file promises, изменение changeCount
и более позднее чужое копирование. Восстановление clipboard не становится разрешением
доставить held input; handover очереди не должен терять исходный clipboard при unresolved Copy.

Для Unicode использовать тот же sender/registry, сохранив `UnicodeReadBoundary`,
complete snapshot provenance, packet limits и inverse preflight. Повторить persistent
count=999, частичный/ignored selection или текстовый packet, ignored Right, cancel
до/после Down, late delivery, outstanding release debt и точный undo. DEBUG Unicode
остаётся выключенным по умолчанию до своей приёмки.

Для обоих движков необходимы healthy control, отказ с последующим вводом, focus,
Secure Input/TCC/tap-loss, OFF/quit/deinit, занятый owner и насыщение reservation.
Переиспользуются существующие Coordinator/recovery UI и custody; новый диагностический
интерфейс не служит заменой реальной связи engine → sender → ledger → disposition.
Задачи 2.2/2.3/6.1/6.2 остаются открытыми до выполнения этих критериев.
