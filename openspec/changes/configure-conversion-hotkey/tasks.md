## 1. Модель и распознавание

- [x] 1.1 Добавить валидируемую модель и сохранение с default/fallback; проверить unit-тестами roundtrip и повреждённые данные.
- [x] 1.2 Добавить чистый детектор с single-shot и reset; проверить RU/EN keyCode, extra modifiers, synthetic, repeat и double Shift.

## 2. Система и интерфейс

- [x] 2.1 Добавить системную регистрацию и сохранение прежней настройки при отказе; проверить модельными тестами lifecycle и отказ регистрации.
- [x] 2.2 Добавить настройки и подключить ручной pipeline; проверить build, UI и ручную конвертацию/undo в собственном документе.

## 3. Приёмка

- [x] 3.1 Выполнить make test, build/Release, strict CI и OpenSpec validate; записать результаты и ограничения в документацию.

## 4. Option+Space

- [x] 4.1 Разрешить Option+Space и добавить «Пробел» в UI; проверить валидатор, persistence, repeat, обычный пробел и живые conversion/undo без лишнего пробела, build/test/strict CI.
