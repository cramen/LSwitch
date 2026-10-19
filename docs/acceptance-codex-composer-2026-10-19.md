# Исправление поля Codex — 19.10.2026

Change: `fix-codex-composer-conversion`.
Пользователь уточнил приложение: `com.openai.codex`, не отдельный ChatGPT.

## Причина и исправление

Исходный журнал: AX text-write-not-confirmed, восстановление исходной каретки,
result=failed без переключения TIS. Профиль теперь выбирает clipboard и native
selection/Copy/Paste до прямой AX-записи. Не добавлялся fallback после failed setter;
guards полного текста, выделения, фокуса и clipboard остались прежними.

## Проверки

- 1151 unit-тест, 0 failures/skips; новый интеграционный тест маршрутизации
  исключает AX engine и проверяет native selection, точный undo и clipboard.
- Debug/Release build, 27 protocol groups и strict SwiftLint: CI `8d6947f`,
  https://github.com/cramen/LSwitch/actions/runs/39239885427 .
- `openspec validate --all --strict`: 8/8.
- Бинарник SHA256 `30f6158418e412971b4b227c1d2670cec632ca8837d9bc9d78630dbefd8a43e4`.
- CUA запрещает управление Codex; никаких обходов через AX/CGEvent-драйвер к Codex
  не выполнялось. Пользователь сам набрал ghbdtn в пустом поле с ABC, нажал
  Option+Space и повторил для undo; подтвердил точный исходник без добавочного текста.
- Журнал живого LSwitch PID 83448: id 1–6 — три converted/undone пары, engine=clipboard,
  reason=none, TIS EN↔RU подтверждён readback. Время операций 242–318 мс;
  это ручной сценарий, не принятие автоматического бюджета 200 мс.
- Чистый повтор id 9/10: converted/undone, 282/242 мс; пользователь подтвердил результат.
  Аудитор сравнил fingerprint и все типы clipboard: matches=true, 1 item/3 types,
  changeCount 3302→3306. Payload оставался в памяти, в вывод не попадал.
- Первый длинный интервал аудита изменил fingerprint (4→3 types); пользователь не помнит,
  копировал ли что-либо. Этот интервал не принят доказательством сохранности.
  Более новое содержимое сохранено, старый снимок не восстановлен; чистый повтор
  начат с нового baseline. Оба аудитора завершены.

## Границы

Подтверждён ручной сценарий в пустом composer с кареткой в конце, не вся матрица
rich/multiline/середины текста и не автоматика. Между сериями в журнале id 7/8
есть expectedSpanMismatch до мутации; их неизвестный пользовательский сценарий
не объявляется успешным и проверки не ослаблялись. Непроверенные диапазоны
по-прежнему могут безопасно отказывать. fix-input-recovery остаётся отдельным change.

## Установка

Та же проверенная сборка установлена в `.build/LSwitch.app` и запущена.
Предыдущая: `.build/LSwitch-before-codex-composer-20261019.app`.
Пользовательский Option+Space сохранён, enabled ON, auto OFF, sound ON.
Логи: `.build/codex-composer-{test,release,protocol,live}.log`.
