## Why

В Codex (`com.openai.codex`) ручной хоткей выделяет текст, но AXSelectedText не меняет
содержимое редактора. Журнал подтверждает text-write-not-confirmed и возврат каретки.

## What Changes

- Выбрать clipboard/native-keyboard путь до попытки прямой AX-записи для Codex.
- Сохранить guards полного текста, диапазона, фокуса, clipboard и точного undo.
- Проверить исправление в пустом черновике без отправки сообщения.

## Capabilities

### New Capabilities

- `codex-composer-conversion`: проверяемая ручная конвертация в поле сообщений Codex.

### Modified Capabilities

Нет.

## Impact

AppProfiles и регрессионные тесты маршрутизации. Не распространяется на отдельное
приложение ChatGPT и не закрывает fix-input-recovery либо всю матрицу редакторов.
