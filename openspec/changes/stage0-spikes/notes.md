# Заметки по верификации спайков (этап 0)

Исторические AX ≥3/5 и полное восстановление promises ниже описывают прежние
критерии. Их согласованная замена и незакрытый остаток зафиксированы в разделе
[«Решение по механизмам и promises»](#решение-по-механизмам-и-promises-2026-10-15).

Начальные разделы ниже сохранены как исторический протокол. Актуальное дополнение —
[Chrome и длительная диагностика](#chrome-и-длительная-диагностика-2026-10-15);
оно не превращает прежние skip или незакрытые ручные сценарии в выполненные.

Дата: 2026-10-14. Машина: macOS, Xcode полный (через DEVELOPER_DIR), без
codesigning-сертификатов.

## Что проверено автоматически

- `swift test`: 42 теста зелёные (1 интеграционный tap-тест скипается без
  разрешения Input Monitoring). CI на GitHub Actions: build + test +
  SwiftLint — зелёные (cramen/LSwitch).
- Smoke-запуск menu-bar агента: стартует, живёт, в idle 0% CPU, ~1.4 MB RSS.
- `lswitch --probe` (обычная и sandbox-сборка одного бинарника):
  - sandbox entitlement применяется (проверено SecTask);
  - AX под sandbox: `kAXErrorAPIDisabled` (-25204) — AX-режим под sandbox
    невозможен → ADR-001: без sandbox, дистрибуция вне MAS;
  - `tapCreate` создаётся в обеих сборках, но без разрешения Input
    Monitoring события не доходят (доставка молчит 2 с);
  - `CGPreflightListenEventAccess` возвращает `true` из-за наследования
    TCC-контекста терминала — для реальных проверок нужна стабильная
    подпись (ad-hoc сбрасывает разрешения при пересборке).

## Находки из живого тестирования (этапы 1–2)

- TextEdit: AX-режим и clipboard-режим работают (ручная и авто-конвертация).
- **Obsidian (Electron): AX-запись молча вставляет текст у курсора вместо
  замены диапазона** — `AXUIElementSetAttributeValue` возвращает success.
  Лечится верификацией записи чтением + clipboard-fallback с выделением
  слова через ⌥⇧← (реализовано в этапе 2).
- TIS API и NSWorkspace — только с главного потока: вызов из фонового Task
  убивает процесс (`_dispatch_assert_queue_fail` в HIToolbox).

## Что осталось ручной проверкой (нужны клики в TCC)

Разрешения Accessibility / Input Monitoring выдаются только интерактивно —
автоматизировать нельзя. Разрешения уже выданы (бандл подписан self-signed
«LSwitch Dev», переживает пересборку — см. `docs/dev-setup.md`).

ВНИМАНИЕ: пункты меню «Спайк: …» удалены в этапе 1 — продуктовая логика
заменила их. Для проверок ниже используй продуктовые сценарии (двойной
Shift, автопереключение) и `lswitch --probe`; восстановление tap
(2.3/2.4) наблюдается по логам EventTapCore (`recoveryCount`).

1. «Спайк: перехват» — счётчики в «Статус спайков…»: синтетические события
   (генерирует «Спайк: конвертация через буфер») должны помечаться
   `synthetic` (задачи 2.1, 2.2).
2. Sleep/wake, `tapDisabled`, Fast User Switching — tap восстанавливается,
   растёт `recoveryCount` (2.3). Длительный прогон 8 ч (2.4).
3. «Спайк: конвертация через AX» в TextEdit / Safari / Chrome / Telegram /
   VS Code — критерий ≥ 3 из 5 (3.1, 3.3). Поле пароля — отказ (3.2).
4. «Спайк: конвертация через буфер» в TextEdit/Chrome — fingerprint буфера
   до/после совпадает (4.2, 4.3). Проверить ленивые pasteboard promises
   (open question из design D5).
5. После завершения ручных проверок: отметить P0.1–P0.3 в TZ.md и обновить
   статус в README (задача 5.3).


## Продолжение этапа 0: маркер и типы clipboard (2026-10-15)

### Среда, команды и результат

macOS 14.5, Apple Silicon, полный Xcode через Makefile/`DEVELOPER_DIR`.
Проверка выполнялась командой `make test`; все clipboard-fixtures используют
частные именованные NSPasteboard и временные файлы. Системный `.general`
этими тестами не изменяется. Для интеграции tap доступны разрешения чтения
и отправки событий.

- Первый исправленный общий прогон 2026-10-14: **242 теста, 0 ошибок, 0 пропусков**.
- Последний общий локальный прогон 2026-10-15: **254 теста, 0 ошибок, 0 пропусков**.
- В обоих прогонах `PasteboardSnapshotTests` прошёл все 10 тестов, а обе
  интеграции настоящего tap завершились успешно без skip.
- Локальные логи: `.build/continuation-third-tests.log` и
  `.build/continuation-login-tests.log`. Это локальные файлы сборки, не опубликованные
  артефакты CI. Прежний CI из архива исправлений не приписывается новому набору.

### Задача 2.2: реальная доставка маркера

[EventTapTests.swift](../../../Tests/LSwitchCoreTests/EventTapTests.swift), тест
`testSyntheticMarkerSurvivesRealTapDeliveryWithoutRecursion`, создаёт настоящий
`EventTapCore` и последовательно публикует два **keyUp**: внешний и маркированный.
В callback проверены `raw.isSynthetic == false` / `true` соответственно и
ровно одна доставка каждого события. Глобальные keyDown и ввод символов в
пользовательское окно для этой проверки не отправлялись.

`testMarkedKeyDownImageIsExcludedFromDownstreamProcessing` отдельно создаёт
keyDown-объекты только в памяти, без post. Он подтверждает, что собственная
синтетика не классифицируется как ввод, не добавляется в буфер слова и не
запускает детектор хоткея; внешний образ обрабатывается.

Отсутствие разрешений/внешней доставки остаётся явным skip окружения. После
успешной внешней доставки отсутствие маркированного события или неверный флаг
является failure, не skip. Здесь оба события получены — задача 2.2 закрывается
по реальному локальному проходу и отдельной проверке downstream-guard.

Во время разработки теста обнаружилась ошибка его идентификации: маркированный
CGEvent был создан до ожидания внешней доставки, а пришёл с другим timestamp.
Диагностика показала `isSynthetic=true`; ошибочно отбрасывался именно timestamp.
Событие теперь создаётся и получает свежую метку времени непосредственно перед
post, matcher регистрирует прочитанный timestamp. Проверки маркера не ослаблялись.

### Задача 4.1: реальные unit-fixtures и fingerprint

[PasteboardSnapshotTests.swift](../../../Tests/LSwitchCoreTests/PasteboardSnapshotTests.swift)
проверяет смешанный pasteboard из четырёх items:

- UTF-8 текст с Unicode/emoji, корректный RTF и дополнительный бинарный тип одного item;
- корректный PNG 2×2 с известными RGBA-пикселями;
- два `fileURL`, указывающие на реально созданные текстовый и PNG-файл, включая имя с пробелом и кириллицей.

После capture → временная запись → restore подтверждены полный снимок и
побайтовое равенство всех доступных типов, порядок items и fingerprint.
RTF декодируется с исходным текстом/атрибутом шрифта; PNG декодируется с
точными размерами и RGBA-пикселем; восстановленные URL читаются системным
pasteboard-reader и ведут к исходным байтам двух файлов.

Дополнительные тесты проверяют пустой clipboard, стабильность fingerprint при
другом порядке объявления типов, изменение хэша при изменении/перестановке
items. В сериализации хэшируемых данных исправлена реальная неоднозначность:
`type=org.lswitch.a + data=bc` и `type=org.lswitch.ab + data=c` раньше совпадали
по входному потоку SHA-256. Длины и признак наличия данных теперь отделяют поля.
Это исправление кодирования границ, а не заявление об отсутствии криптографических коллизий.

Проверка настоящего `ClipboardConverter` с мок-редактором и частным системным
pasteboard подтверждает восстановление смешанного снимка. Отдельная запись
нового файлового URL во время операции сохраняется: старый снимок её не затирает,
а отменённая операция не меняет редактор. Задача 4.1 закрывается в unit-объёме.

Две первоначальные ошибки fixture/oracle также исправлены без ослабления
проверок: общий `NSPasteboard.data(forType: .rtf)` объединял несколько items,
поэтому исходные bytes проверяются на нужном item; PNG теперь задаётся и
проверяется точными RGBA-компонентами без пересчёта через display/device color space.

### Что этим не подтверждено

- Задачи 2.3–2.4: восстановление после настоящего системного отключения,
  sleep/wake, смена сессии, внешняя физическая клавиатура, 8 часов и hot path ≤1 мс.
- Задача 3.3: исходная AX-матрица ≥3 из TextEdit/Safari/Chrome/Telegram/VS Code.
- Задачи 4.2–4.3: живая clipboard-матрица TextEdit/Chrome, отдельные клавиатурные
  Cmd+C/V RU/EN, реальные внешние providers/receivers, позднее чтение и file promises.
  Файловый URL не является доказательством работы file promise.
- Полный sandbox-прогон 5.1 и завершение/итоговая повторная сверка 5.3.
  Обновление README/TZ отражает текущий статус, но не закрывает эти критерии.

## Итоговый CI продолжения — 2026-10-15

[CI кода `8a23a8a`](https://github.com/cramen/LSwitch/actions/runs/38639305713)
завершён успешно: сборка, **255 тестов без ошибок и пропусков**, SwiftLint strict
**0 нарушений в 63 Swift-файлах**. Программный код отправлен в `main`.

Первый CI `f87ede6` прошёл build/test и выявил два замечания линтера:
сложность `Converter.trigger` и лишнюю пустую строку в тесте. Завершение
конвертации выделено в отдельный метод, строка удалена; повторный локальный
`make build`/`make test` и указанный CI прошли. Правила CI не менялись.

Этот результат подтверждает автоматические проверки и не закрывает оставшиеся
живые матрицы, длительный прогон и измерение задержки.

## Chrome и длительная диагностика, 2026-10-15

Общий локальный прогон на 322 тестах (02:39 МСК) и следующий на 329 тестах
(10:25 МСК) прошли без ошибок и пропусков. Последний включает барьер доставки
событий перед началом преобразования и готовый AX-снимок. Работающий длительно
`.app`, PID 81843, на момент того наблюдения был сборкой на 322 тестах; SHA-256 и локальные
логи зафиксированы в [общем протоколе](../../../docs/acceptance-2026-10-15.md).
На том шаге последний опубликованный CI `3a28be9` относился к серии на 255 тестах;
новый рабочий код пока не имеет собственного CI.

Настоящее отключение tap через `CGEvent.tapEnable(false)` и последующая внешняя
доставка keyUp после watchdog прошли интеграционный тест без skip. Старые queued
events отсекаются при восстановлении. Это подтверждает часть 2.3; sleep/wake,
Fast User Switching и переподключение устройства отдельно не приняты.
Пользователь подтвердил отсутствие внешней клавиатуры. Восьмичасовая часть
наблюдения конкретного бинарника завершена: на 10:43:34 МСК uptime tap
28 859,874 с, 240 callback, максимум 873 125 нс, превышений 1 мс нет.
Все 481 периодическая запись имеют один PID/instance, running/enabled,
интервал не больше 60 с; recovery/wake/session notifications — 0.
CPU/RSS измерены только в последнем получасе, не за весь интервал.
На момент этой точки физический ввод ещё не был подтверждён; позднее пользователь
получил `привет мир`, результат проверен через UI. Sleep/wake отложен пользователем,
поэтому полная 2.4 открыта.

В Chrome воспроизведено отложенное AX-выделение, которое позднее затирало слово.
Добавлено подтверждение устойчивого диапазона и cleanup; неоднозначная AX-мутация
не повторяется fallback. Chrome заранее выбирает keyboard Paste, поскольку
проверенный AXPress принимался без фактической вставки. Принудительный Latin Unicode
команд заменён нативным Unicode текущей раскладки. Живые RU→EN с быстрым продолжением
и EN→RU прошли с точным текстом и сохранённым hash clipboard. Это не завершает 4.2:
полная TextEdit/Chrome и резервная Cmd+C/V RU/EN матрица ещё не приняты.

Исходная AX-матрица 3.3 остаётся открытой. Clipboard-проходы Chrome/Safari/VS Code
не считаются AX-успехами. Полная 4.3 также открыта: production отказывается
от невосстановимых snapshots/file promises до изменения clipboard; частное
исследование materialized legacy promise не доказывает весь lifecycle и modern
receivers. `setup-unconfirmed` modern baseline не является доказательством
невозможности восстановления. Подробные результаты и оставшиеся шаги — в общем протоколе.

Отдельные подписанные sandbox/non-sandbox probe-бандлы из исходников набора 329
прошли по три частных clipboard-сценария: смешанный snapshot с RTF/PNG/файлами,
ленивый provider и отказ до clear при nil-данных. Оба LaunchServices-процесса
сообщили AX/listen/post=false, новых TCC-разрешений не получали. Direct CLI
preflight из терминала не считается разрешением самого бандла. Полный 5.1
остаётся открытым для AX/tap; первые normal file-fixtures в Documents зависли
в системном выдающем sandbox-extension вызове, повтор из `/private/tmp` прошёл.
Причина зависания не доказана; отчёты и SHA сохранены в общем протоколе.

README/TZ обновлены честными текущими границами; требуемая формулировкой
5.3 повторная сверка после оставшихся проверок пока не завершена.

## Новые бинарники и modern promise, 2026-10-15

Общие локальные build/test/app на 371 (11:01 МСК) и 379 тестах (11:16 МСК)
прошли без ошибок и пропусков; на этом шаге собственного CI нового кода ещё не было. Сборки и SHA
разделены в [общем протоколе](../../../docs/acceptance-2026-10-15.md).
Восьмичасовая сессия 322 не распространяется на них. Последняя точка сессии 371,
11:25:53 МСК: 975 callback, максимум 4,749458 мс, два превышения 1 мс,
p99 upper 1 мс, recovery 0. Hot path нового кода этим не принят.

В 379 первый Chrome RU→EN подтвердился за 318,850 мс; следующий EN→RU отказал
по `clipboardCaptureTimedOut` до мутации. В 371 были capture timeout и отдельный
неподтверждённый Paste с cleanup и сохранением текста/clipboard. Это конкретные
результаты, не закрытие полной 4.2 или цели ≤200 мс.

Modern UI fixture теперь имеет валидный исходный baseline: настоящий
NSFilePromiseProvider записал файл, NSFilePromiseReceiver получил точные bytes
в новый destination. Exact raw replay на новом private pasteboard сохранил
items/types/Data, но не дал callback за 20 с ни при живом owner, ни после реальных
deinit provider/delegate. Исходный файл сохранён, оба новых destination пусты.
General clipboard не затрагивался. Сессия
`/private/tmp/LSwitchPromiseLab-4FACE159-0834-4497-9DC8-8375171CEAEC`,
детали — `.build/promise-lab/research.md` и общий протокол.
Этот результат не отменяет положительный legacy-контроль и не доказывает
невозможность всех promises. Безопасный отказ production сохраняется; 4.3 открыта.

Составные задачи не закрывались, архивирование stage0 не выполнялось.

## Решение по механизмам и promises, 2026-10-15

Пользователь явно делегировал оба решения с приоритетом качества после предъявления
ограничений. Принята полная продуктовая матрица каждого исходного
TextEdit/Safari/Chrome/Telegram/VS Code с выбранным безопасным механизмом: AX
при подтверждённой записи, иначе заранее выбранный clipboard-профиль. Она заменяет
исследовательский порог AX ≥3/5; старый порог **не объявляется пройденным**.
Для каждого приложения остаются точные текст/каретка, продолжение ввода, undo,
fingerprint clipboard и исходная цель автоматической задержки ≤200 мс.
Safe refusal обычной текстовой конвертации не закрывает строку матрицы.

AX-only379 подтвердил ограничение: Chrome/Safari/VS Code — `text-write-not-confirmed`.
Cleanup каретки true/true/false соответственно; в VS Code текст сохранён, каретка
не подтверждена. Отдельный clipboard-проход после такой попытки не запускается.
Логи `.build/matrix-379-{chrome,safari,vscode}-ax-{manual,diagnostics}.log`.
3.3 остаётся открытой: Telegram и полный набор проверок выбранных путей не приняты.

Для неподдержанных file promises согласован явный безопасный отказ **до** изменения
текста, выделения и clipboard с сохранением исходного owner/provider. Modern raw
replay исследование обосновывает этот выбор, но не является всей приёмкой.
Нужно подтвердить приём исходного promise настоящим receiver после production-отказа.
Обычные текст/RTF/PNG/файлы, смешанные items, материализуемые ленивые providers,
приём реальными приложениями и сохранение более нового копирования остаются обязательными.
4.3 открыта; raw Data и fileURL не подменяют provider lifecycle.

Proposal/spec/design/tasks и README/TZ приведены к этому явному решению.
История не переписана в PASS; составные задачи не закрывались и не архивировались.

## Контрольная сборка 417 и реальные форматы, 2026-10-15

`make build`, `make test`, `make app` прошли; **417 тестов, 0 ошибок, 0 пропусков**,
12:44:36 МСК. Логи `.build/acceptance-native-eof-tis-{build,tests,app}.log`.
Запущен отдельный PID 28729 с SHA-256
`6a74a46b5c3e2ead54bfd5d96b808dfee988d24a18e1ec1da19afd81e4664a1b`;
на этом шаге нового опубликованного CI ещё не было, `3a28be9` подтверждал прежний код.
Точка 13:35:05 МСК: 136 callback, max 0,523750 мс, 0 превышений 1 мс/recovery,
uptime tap 2 939,899 с. Это короткая серия, а не перенос восьмичасового PASS322.

Helper теперь использует официальный terminationHandler и EOF вместо polling
`waitUntilExit`. Частный benchmark100 подтвердил уменьшение post-EOF ожидания
до 0,054 мс. Live capture393: 43,629 мс до mainCompletion; live417 helper
39,865/48,511 мс в двух сохранённых сценариях. Однако первый Paste Chrome 417
не подтверждён, cleanup выполнен. На собственной диагностической странице
и затем нейтральной странице с метаданными только в RAM конвертации прошли.
Причина непостоянного результата ещё не установлена. Ручные 316,830 мс не
принимают автоматическую цель ≤200 мс и не закрывают полную 3.3/4.2.

Приняты конкретные реальные provider/receiver сценарии после конвертаций:

- Styled RTF из TextEdit → Chrome 393 → TextEdit: исходный fingerprint всех трёх
  типов сохранён, текст и жирное оформление приняты в тестовом receiver-документе.
- PNG из Preview → Chrome 417 → Preview New From Clipboard: fingerprint двух
  типов сохранён, receiver принял изображение 2×2.
- Два файла из Finder → Safari 417 → Finder: fingerprint двух items (3/1 типа)
  сохранён, bytes обоих принятых файлов равны исходникам.

Полные SHA и локаторы — в [общем протоколе](../../../docs/acceptance-2026-10-15.md),
файловый контроль — `.build/clipboard-files-receiver-verification.json`.
Это обычные файлы, не promises. На этом шаге гонка нового копирования и genuine
general promise с последующим receiver ещё не запускались; их позднейшие результаты
зафиксированы ниже. Составная 4.3 остаётся открытой.

## Внешняя запись, legacy promise и зелёный CI, 2026-10-15

На том же LSwitch417 PID 28729 выполнена настоящая межпроцессная запись в general
clipboard: после временного текста LSwitch сторонний тестовый процесс записал marker.
Count3211→3212→3213; marker сохранён, приложение отказало с `clipboardChanged`
до изменения выделения/Paste, слово Safari осталось исходным. Это PASS данного
foreign-write сценария, не физический Cmd+C или доказательство атомарного CAS.
Логи `.build/clipboard-race-417-safari-v2.jsonl` и
`.build/clipboard-race-417-safari-v2-diagnostics.log`; условия — в общем протоколе.

Modern NSFilePromiseProvider в General дал `SETUP UNCONFIRMED` и до, и после
production-отказа: исходный receiver baseline отсутствует. Этот результат не PASS.
Отдельный genuine Carbon legacy promise в General принят полностью:

- A/count 3217: исходный receiver baseline PASS в 14:11:52 МСК.
- Свежий B/count 3218 опубликован в 14:12:43, без предварительной материализации.
- В 14:12:56.957 LSwitch отказал `clipboardNotRestorable` до мутации.
- В 14:13:18 настоящий receiver вызвал новую запись provider в новый destination,
  получил точные bytes; owner/count 3218 сохранены.
- Собственная публикация очищена в 14:13:48, count 3219; исходный пустой clipboard возвращён.

Payload SHA `a7894dfc098c0ff145636c4bc122ac97352e236756484cbcbbebe51111cbca7a`.
Лаборатория `/private/tmp/LSwitchPromiseLab-4CBC7027-0FF5-478D-9AFD-5B69F7A5686A/events.jsonl`;
`.build/legacy-promise-417-safari-{driver,diagnostics}.log`. Это PASS конкретного
preservation/receiver контракта после отказа, не перенос на modern baseline.
Полная 4.3 остаётся открытой для остальной прикладной/форматной матрицы и
материализуемых ленивых providers.

[CI `2ca1f03`](https://github.com/cramen/LSwitch/actions/runs/38725549370) завершён
15 октября в 14:12:24 МСК: build, 417 тестов без ошибок, SwiftLint strict
0 нарушений в 118 файлах. Предыдущие checkpoint `66f3cdc` и style fix `85c0b07`
прошли build/test, но получили соответственно 12 и 1 замечание lint; история сохранена.
Незакоммиченные Unicode engine/helper capability в разработке и не покрыты этим CI.
Составные checkbox и архивирование не менялись.

## Локальный checkpoint 489: Unicode и обратное выделение

`make build`, `make test`, `make app` прошли 15 октября в 15:12 МСК:
**489 тестов, 0 ошибок, 0 пропусков**. Логи `.build/unicode-boundaries-{build,tests,app}.log`.
SHA `21a1a5a2777d8260de8ab6b99fbc55911d2151f21591c698e493d1e3a6c1a890`;
после DEBUG-сценариев запущен обычный режим PID 46088,
`.build/acceptance-489-normal.jsonl`. Unicode остаётся DEBUG-only, default выключен.
На момент локального прогона green CI был `2ca1f03` с 417 тестами; последующий
checkpoint `2abf560` подтвердил 489, см. дополнение ниже.

Chrome 467 подтвердил auto в обе стороны, продолжение `world hello` и receipt undo,
включая исходный NBSP в rich. Auto467–489 занял 289–337 мс: цель ≤200 мс не пройдена.
Первый 470:300,724 мс, engine 274,679 мс, isCurrent/documentIdentity/snapshot 215/59/11;
первый 489:291,461 мс, engine 253,895 мс, вызовы 149/42/10. Вложенные длительности
не суммируются. Никакой следующий performance-план этим не объявляется реализованным.

На 467 выбранное слово в середине `prefix ghbdtn suffix` заменилось, но undo отказал
`keyboardSelectionRequiresDocumentEnd`. Исправление 489 проверяет обратный диапазон
до замены: Unicode22,204 мс и normal clipboard 47,499 мс отказали
`keyboardUndoUnavailable` без capture/write, с исходными текстом/выделением/count 3222.
Это PASS безопасного отказа, не поддержка middle selection.

В обычном 489 ручной Safari `ghbdtn`→`привет` прошёл за 196,593 мс с TIS EN→RU,
захватом через зарегистрированный helper и восстановлением пустого clipboard,
итоговый count 3224. Manual196,593 мс не является autoPASS200 мс.
Лог `.build/matrix-489-normal-safari-helper{,-diagnostics}.log`.
Прочие сценарии/точные SHA и числа — в [общем протоколе](../../../docs/acceptance-2026-10-15.md).
Составные задачи не закрывались; legacy promise/race PASS сохраняют свой отдельный объём.

## CI 489 и статус Telegram, 2026-10-15

[Checkpoint `2abf560`](https://github.com/cramen/LSwitch/actions/runs/38734859621)
прошёл CI в 15:29 МСК: build,489 тестов без ошибок/пропусков, SwiftLint strict
0 нарушений в 143 файлах. Лог `.build/checkpoint-2abf560-ci.log`.
Следующая рабочая оптимизация `UnicodeReadBoundary` этим CI не покрыта и не принята.
Unicode остаётся DEBUG-only; ограничения и превышение 200 мс сохраняются.

Telegram: CUA-открытие отклонено автоматической проверкой безопасности.
Разрешение на отдельное пустое «Избранное» без отправки сообщений запрошено;
на том шаге ответ ещё ожи дался. Статус был `blocked-by-permission`, строка не проверена,
обход другим инструментом не выполнялся. Составные checkbox не менялись.

## Локальная 503: VS Code и физический Telegram

15 октября в 15:59:38 МСК build/test/app подтвердили **503 теста без ошибок/пропусков**;
`.build/unicode-boundary-vscode-{build,tests,app}.log`. SHA
`8d53d7826d1035d986656ef8f6e69923a57c95ea71fa5b08fef47c2c8dbf8ffb`, normal PID 50457,
`.build/acceptance-503-normal.jsonl`. ReadBoundary/permission boundaries,
captured PID и D13 default gate включены; собственного CI 503 ещё нет.
На этом шаге Chrome performance503 ещё не измеряли; поздний 503b замер приведён ниже.
Живая проверка gate выполнена ниже.

VS Code 489 сначала подтвердил manual/receipt undo за 260,467/245,265 мс,
но reverse попытка вставила `приветghbdtn` (Col 13) вместо замены. Журнал:
`textNotConfirmed`342,762 мс, затем `expectedSpanMismatch`; пустой clipboard сохранён,
count 3230. Поэтому 503 отказывает по `unverifiedEditorModel` по умолчанию;
пять unit-проверок прошли, рабочей совместимости VS Code это не означает.
Логи `.build/matrix-489-normal-vscode-{manual-undo,reverse-undo}{,-diagnostics}.log`.

Пользователь разрешил Telegram, прежний блок допуска снят. CUA предоставлял только
окно/меню, без доступного поля и screenshot; после разрешённой активации и Cmd+0
ввод агентом не выполнялся, сообщения не отправлялись. Пользователь проверил
собственное «Избранное» физически. Первый опыт дал две конвертации за 176,509/164,477 мс
с gap 4,2 с, поэтому точным undo не считается. Повтор дал две реальные пары:
converted 158,306/undone 132,983 и converted 133,592/undone 123,210 мс,
engineAX, auto=false, обе TIS RU→EN→RU. Исходный текст визуально подтверждён
пользователем. Лог `.build/matrix-503-telegram-human-undo-repeat.log`.
Manual AX/receipt undo — PASS конкретного сценария. Затем пользователь физически
набрал `ghbdtn` Space `vbh` Space и подтвердил «привет мир». Журнал операции 7:
AX, auto=true, repeat после шести manual, EN→RU, 176,789 мс, target200=true.
Это PASS одного прогретого auto, не cold start; clipboard empty/count 3230/hash сохранены.
Лог `.build/matrix-503-telegram-human-auto.log`. Задача 3.3 остаётся открытой.

Живой VS Code 503 default-отказ `unverifiedEditorModel` подтверждён за 6,369 мс
до snapshot/capture/write/selection: исходные `приветghbdtn`, Col 13 и clipboard3230
не изменены. `.build/matrix-503-normal-vscode-refusal{,-diagnostics}.log`.
Это PASS безопасного отказа, не совместимость VS Code. После human auto через UI
восстановлены autoOFF, enabledON, soundON, loginOFF, undo 3 с, learning 2, пустые исключения.

## 503b: первый Chrome auto и регистрация Login Item

Build/test/app 503b прошли 15 октября в 16:31:10 МСК: 503 теста, 0 ошибок/пропусков,
`.build/503-caption-{build,tests,app}.log`. Нейтральная подпись notFound включена
без изменения поведения. Бинарник
`72acf06bc6f6dc821ae5f5d959bbf53aae78bea8e17ef125f72ebc1e0032e5c0`, PID 54012,
DEBUG unicodeChrome; `.build/acceptance-503b-unicode-chrome.jsonl`.

Первый фактический Chrome EN→RU auto завершился `converted` за 261,394 мс,
TIS RU подтверждён; CUA показал точное `привет ` с ASCII-пробелом.
Пустой clipboard/count 3230/hash 338a3d… сохранён. Это текстовый PASS, latency ≤200 мс FAIL.
Engine 240,078 мс; isCurrent 66/67,889 мс, documentIdentity 22/24,036 мс,
snapshot 10/17,329 мс. Inclusive длительности не суммируются.
Лог `.build/matrix-503b-chrome-auto-first-en-diagnostics.log`.

Свежий UI-цикл Login Item OFF/notFound→ON/enabled→OFF/notRegistered прошёл
без ошибок; status после register/unregister перечитан системным адаптером через
Controller.refresh. Локатор `.build/login-503b-ui-on-off.json`.
Logout не выполнялся; pending/error/фактический вход не приняты.
Это частичный прогресс, составные задачи не закрывались; новый CI 503b ещё требуется.

## 513: settlement seed, прогретые точки и открытый rich undo

Локальные build/test/app прошли с 513 тестами без ошибок/пропусков в 17:14:03 МСК,
`.build/settlement-seed-{build,tests,app}.log`. PID 58184, запуск 14:14:53Z,
SHA `3711cb2ceb1d13f217ad5c71d85b6531cd24915a52bedde319dc93ce0afa51d4`,
DEBUG unicodeChrome, `.build/acceptance-513-unicode-chrome.jsonl`.
Review изменения seed замечаний не выявил; устранены повторы guards, но сохранены
границы проверок, два readback через 20 мс, максимум четыре и cleanup.
Default Unicode OFF; своего CI 513 ещё нет, прежний green489 не переносится.

Первый ENauto 256,523958 мс дал точное `привет ` с ASCII-пробелом, TISRU,
но превысил 200 мс. Engine 209,087459 мс, current/identity/snapshot 60/20/9 вызовов.
Повторный RUauto 199,574541 мс и receipt undo 155,491583 мс прошли; UI после undo
подтвердил исходное `цщкдв ` и TISRU. Быстрое продолжение при повторном RUauto
169,697958 мс дало точное `world hello ` с ASCII-пробелами.
Это отдельные прогретые PASS, не вся cold/repeat приёмка.

Rich ENauto 158,376083 мс прошёл и дал `привет`+NBSP, но immediate receipt undo
145,555542 мс failed с `unicodeSnapshotUnverified` после selection, до Down.
Остались `привет`+NBSP/TISRU; исходные `ghbdtn`+NBSP не вернулись. Это открытый
обязательный дефект точного undo, не принятая полная rich-поддержка.
Логи `.build/matrix-513-chrome-auto-{first-en,ru-undo,ru-continuation}-diagnostics.log`
и `.build/matrix-513-chrome-rich-auto-en-undo{,-diagnostics}.log`.
Пустой clipboard/count 3230/hash 338a3d… сохранён. Полные числа и hash — в
[общем протоколе](../../../docs/acceptance-2026-10-15.md). Составные задачи не закрывались.

Короткий tap-контроль 513 на 17:25:53 МСК: PID 58184, uptime 659,870 с,
289 callback, два >1 мс, максимум 3,224292 мс, tapEnabled=true.
`.build/acceptance-513-unicode-chrome.jsonl`; это не hot path PASS и не 8 часов.

Последующая диагностическая 513b прошла build/test/app с 513 тестами без ошибок/пропусков
в 17:31:17 МСК, `.build/snapshot-flags-{build,test,app}.log`. SHA
`7f52d970e38630d83ded9806d2ffecc15503060f9ebe4e9cf92837b32f67c61f`, PID 60726,
старт 14:31:53Z, `.build/acceptance-513b-unicode-chrome.jsonl`, DEBUG unicodeChrome.
Первый id 1 попал в body/webarea без focused editor: providerVerified=false,
editableRoot=false, documentRoot=true, отказ unicodeSnapshotUnverified, поле не изменено.
Это setup-invalid, не cold rich performance FAIL/PASS; название логов
`.build/matrix-513b-chrome-rich-auto-first-ru{,-diagnostics}.log` сохранено как история
намеренного сценария. Затем приняты три отдельные rich-repeat пары 513b:

| IDs | Auto, мс | Receipt undo, мс | CUA после undo |
| --- | ---: | ---: | --- |
| 5/6 | 178,866 | 256,652667 | `ghbdtn`+NBSP |
| 7/8 | 180,817334 | 190,564125 | `ghbdtn`+NBSP |
| 9/10 | 172,584625 | 242,473334 | `ctujlyz`+NBSP |

В этих трассах snapshot_invalid не появился, каждая undo завершилась undone.
Логи `.build/matrix-513b-chrome-rich-{en-undo-focused,en-undo-repeat,today-undo}{,-diagnostics}.log`.
Прежний failed undo 513 не считается исправленным по трём удачным повторам;
полный rich-профиль и cold gate открыты. После двух отмен CUA подтвердил обучение
на собственном `ghbdtn`; удалено только это тестовое исключение, список снова пуст.
Последний clipboard: items 0/count 3236/hash 338a3d… прежний пустой. Между опытами
были фоновые пользовательские конверсии Codex (не acceptance), поэтому count
за всю 513b неизменным не объявляется. Unicode-путь clipboard сам не использует.

Перед checkpoint запущен normal 513b без test-engine, PID 62093/start14:45:49Z,
`.build/acceptance-513b-normal.jsonl`, прежний SHA 7f52d970… . CUA подтвердил перед
restart autoOFF/enabledON/soundON/loginOFF/undo3с/learning2/empty personal exceptions.
Punto/Caramba не запущены; LSwitch оставлен включённым. Аудитор 87281 завершён
exit 0, originalemptyhash338a3d… matchestrue приcount 3238; restore-write не нужен.
Фоновые операции пользователя не позволяют утверждать постоянныйcount всей сессии.
Проверка checkpoint не закрывает всю работу; нестабильный rich undo исследуется дальше.

Последующий [CI `2331661`](https://github.com/cramen/LSwitch/actions/runs/38756602714)
прошёл build, 513 тестов без ошибок/пропусков и SwiftLint strict без нарушений
в 148 файлах (18:02:18 МСК). Отдельный pure-model reproducer реального Core 513b
подтвердил P1: select(7) → постоянный count=999 → failed/Down=0 → release с собственным
range(0,7) → следующий ввод затирает оригинал; healthy control проходит.
Exit 0 reproducer — подтверждение дефекта, не safety PASS. Полный след/hash сохранён
в D11.P1 и общем протоколе. Pending/Right не внедрены; default Unicode OFF.
