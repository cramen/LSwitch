import Carbon
import CoreGraphics
import Foundation

/// Чтение и переключение системной раскладки через TIS API (design D3).
///
/// Раскладка определяется по `kTISPropertyInputSourceID` текущего источника:
/// id содержит "Russian" → ru, "ABC"/"US" → en, иначе раскладка вне пары
/// MVP и конвертация не выполняется.
public final class LayoutManager {

    /// Сопоставление TIS inputSourceID с раскладкой пары ru/en.
    /// Чистая функция — покрыта unit-тестами.
    public static func layout(forSourceID sourceID: String) -> Layout? {
        let lowered = sourceID.lowercased()
        if lowered.contains("russian") { return .russian }
        if lowered.contains("abc") || lowered.hasSuffix("keylayout.us") { return .english }
        return nil
    }

    public init() {}

    /// Текущая раскладка из пары ru/en; nil — неподдерживаемая.
    public func currentLayout() -> Layout? {
        guard let source = currentSourceID() else { return nil }
        return Self.layout(forSourceID: source)
    }

    public func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        return copyStringProperty(of: source, key: kTISPropertyInputSourceID)
    }

    /// ID всех включённых источников ввода — для диагностики нестандартных
    /// раскладок (RU-PC и т.п.).
    public func enabledSourceIDs() -> [String] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { copyStringProperty(of: $0, key: kTISPropertyInputSourceID) }
    }

    /// Переключает системную раскладку на целевую. Возвращает false, если
    /// подходящий источник не найден или переключение не подтвердилось.
    @discardableResult
    public func switchTo(_ layout: Layout) -> Bool {
        guard currentLayout() != layout else { return true }
        guard let source = findSource(for: layout) else { return false }
        guard TISSelectInputSource(source) == noErr else { return false }
        // Переключение не мгновенное — проверяем с паузой и повторяем раз.
        for _ in 0..<2 where currentLayout() != layout {
            Thread.sleep(forTimeInterval: 0.1)
            TISSelectInputSource(source)
        }
        return currentLayout() == layout
    }

    private func findSource(for layout: Layout) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return list.first { source in
            guard let sourceID = copyStringProperty(of: source, key: kTISPropertyInputSourceID) else {
                return false
            }
            return Self.layout(forSourceID: sourceID) == layout
        }
    }

    private func copyStringProperty(of source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
