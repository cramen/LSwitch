# Изолированная приёмка App Sandbox

`build-probes.py` упаковывает **один уже собранный executable** в два приложения:
`ru.cramen.lswitch.probe.normal` и `ru.cramen.lswitch.probe.sandbox`.
Исходные bytes сохраняются до подписи. Обе копии подписываются сертификатом
«LSwitch Dev»; sandbox имеет ровно `com.apple.security.app-sandbox=true`, normal
не имеет entitlements. Temporary exceptions, network, automation и доступ к
произвольным файлам не добавляются. Основной LSwitch и его TCC identity не меняются.

Скрипт не собирает Swift, не запускает приложения, не отправляет события и не
запрашивает разрешения. Повторный запуск требует нового выходного каталога.
В текущем коде запуск probe identity без `--acceptance-probe` выполняет только
`metadata` и завершает процесс; обычный продуктовый перехват не запускается.
Ранее подготовленные bundles на 329 тестах ещё не содержат эту защиту и требуют
явного флага до следующей пересборки. Это ограничение записывается с SHA сборки.

```sh
make build
python3 tools/acceptance/build-probes.py --output .build/acceptance-probes
```

Поддерживается native thin Mach-O 64 bit, получаемый текущим Makefile на arm64/x86_64.
Executable из `make app` с embedded `__TEXT,__info_plist` отвергается: он содержит
основную identity. Используйте результат обычного `make build`. Изменения подписи
меняют полный SHA executable; исходный SHA и хэши **всех Mach-O sections** в
`manifest.json` подтверждают одинаковый код. Скрипт сравнивает их после каждой подписи
и проверяет обе подписи через `codesign --verify --strict`.

`evidence/` содержит сохранённый исходник, entitlements и designated requirement
каждой копии. Одинаковые fixtures находятся в обоих `Contents/Resources/Fixtures`
и отдельно в `fixtures/`; словарный bundle также скопирован в Resources.
Для sandbox используйте путь fixtures **внутри соответствующего приложения**.

## Запуск оператором

Следующие команды — отдельные диагностические действия, а не часть packaging.
Запуск через LaunchServices уменьшает неоднозначность TCC-контекста терминала.
Прямой запуск `Contents/MacOS/LSwitchProbe` не доказывает, что разрешения принадлежат
самому приложению; результаты сравниваются вместе с runtime metadata и состоянием
разрешений каждой отдельной identity. Для каждой команды ожидается завершение процесса.

Пример для normal, затем повторить с `probe_mode=sandbox`:

```sh
probe_root="$PWD/.build/acceptance-probes"
probe_mode=normal
probe_app="$probe_root/LSwitchProbe-$probe_mode.app"
probe_fixtures="$probe_app/Contents/Resources/Fixtures"
/usr/bin/open -n -W -g --stdout "$probe_root/$probe_mode-metadata.json" \
  --stderr "$probe_root/$probe_mode-metadata.stderr" "$probe_app" \
  --args --acceptance-probe metadata
```

`metadata` сообщает bundle ID, подписанный SHA, sandbox entitlement, AX trust,
результат чтения focused application и preflight listen/post. Значения `true` в
preflight сами по себе не доказывают доставку событий. В коде нет запроса TCC;
если система покажет диалог доступа, решение остаётся оператору.

Частные pasteboards, без чтения или записи general clipboard:

```sh
for probe_case in clipboard clipboard-lazy clipboard-unresolved file-promise; do
  /usr/bin/open -n -W -g --stdout "$probe_root/$probe_mode-$probe_case.json" \
    --stderr "$probe_root/$probe_mode-$probe_case.stderr" "$probe_app" \
    --args --acceptance-probe "$probe_case" --fixtures "$probe_fixtures"
done
```

`clipboard` проверяет текст/RTF/PNG/два файловых URL и декодирование после restore.
`clipboard-lazy` проверяет materialization data provider; это не file promise.
`clipboard-unresolved` подтверждает отказ до clear. `file-promise` публикует настоящий
provider, но без полноценной drag session может вернуть `setup-unconfirmed` из-за
пустого окончательного имени; это не доказательство невозможности восстановления.
При наличии receiver запись ограничена собственным временным каталогом процесса.
Ни один частный сценарий не закрывает матрицу принимающих приложений задачи 4.3.

Режим `keyup` оператор запускает отдельно, когда разрешён диагностический ввод:

```sh
/usr/bin/open -n -W -g --stdout "$probe_root/$probe_mode-keyup.json" \
  --stderr "$probe_root/$probe_mode-keyup.stderr" "$probe_app" \
  --args --acceptance-probe keyup
```

Он создаёт **listen-only** session tap, отправляет один keyUp с nonce и проверяет
ровно одну доставку за 2 секунды плюс 100 мс наблюдения дублей. KeyDown не отправляется.
Tap/source удаляются на всех выходах. Это не проверка активного удержания продуктового
tap, физической клавиатуры или восьмичасовой устойчивости. Без подтверждённого normal
baseline с достаточными TCC правами два отрицательных результата несравнимы.

## AX: только подготовленный документ

Оператор через UI открывает **внешнюю копию** `fixtures/LSwitchAcceptance.txt` в TextEdit
и фокусирует её текст. Документ внутри подписанного `.app` не редактируется.
Пробник не открывает окна и не меняет фокус. Marker сверяется полностью; другие
документы и защищённые поля приводят к отказу. Для sandbox ожидаемый исходник передаётся
через base64, чтобы чтение внешнего файла не требовало file-access entitlement:

```sh
probe_document="$probe_root/fixtures/LSwitchAcceptance.txt"
probe_expected="$(/usr/bin/base64 < "$probe_document" | /usr/bin/tr -d '\n')"
/usr/bin/open -n -W -g --stdout "$probe_root/$probe_mode-ax.json" \
  --stderr "$probe_root/$probe_mode-ax.stderr" "$probe_app" \
  --args --acceptance-probe ax --target-bundle com.apple.TextEdit \
  --document "$probe_document" --expected-base64 "$probe_expected"
```

По умолчанию это capabilities-only. Добавление `--write` — отдельное явно разрешённое
действие: замена `ghbdtn` → `привет`, подтверждение и восстановление исходника/выделения.
Для Chrome и clipboard-профилей write запрещён; capability report не считается AX pass.
Фокус, PID, AXDocument, точный текст и UTF-16 range перепроверяются на каждом этапе.
Подтверждение ограничено четырьмя чтениями с паузами 20 мс; неизвестное изменение
запрещает дальнейшую запись. `unconfirmed`/`originalRestored=false` требуют проверки
тестового документа оператором и не засчитываются как успех.

Каждый AX read/write/settable предваряет `AXUIElementSetMessagingTimeout(..., 0.1)`;
при отказе установки таймаута IPC не выполняется. Metadata устанавливает этот же
timeout для system-wide объекта, то есть default всего процесса (локальный SDK,
`HIServices/AXUIElement.h`, описание `AXUIElementSetMessagingTimeout`). В отчёте
сохраняются значение timeout, результат его установки и факт попытки чтения.
Это ограничение отдельного AX вызова, а не общий deadline всех этапов; синхронные
NSPasteboard IPC по-прежнему используют системные таймауты. Старые bundles на 329
тестах этих изменений не содержат, новый протокол требует пересборки и нового SHA.
При отказе AX он не вызывает `AXIsProcessTrustedWithOptions` и не предлагает выдачу TCC.
Для содержательного сравнения normal должен подтвердить хотя бы capabilities и
разрешённый round trip; отказы normal без прав не доказывают ограничение sandbox.

Результаты каждого режима записываются отдельно с исходным SHA из manifest,
подписанным runtime SHA и реальным состоянием TCC. Packaging и подпись сами по себе
не закрывают задачу 5.1 OpenSpec; результаты исполнения вносятся в её протокол.
