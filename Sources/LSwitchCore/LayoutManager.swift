import Carbon
import CoreGraphics
import Foundation

/// Чтение и переключение системной раскладки через TIS API (design D3).
///
/// ВНИМАНИЕ: TIS/HIToolbox требует главный поток (assert в
/// TISCopyCurrentKeyboardLayoutInputSource). Вызывать только с main thread
/// (в `Converter` это делает переход на MainActor).
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
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let identifier = source.flatMap { copyStringProperty(of: $0, key: kTISPropertyInputSourceID) }
        #if DEBUG
        if Thread.isMainThread {
            MainActor.assumeIsolated { TISSourceDiagnostics.recordRead(layoutSourceID: identifier) }
        }
        #endif
        return identifier
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
    /// true подтверждает текущий источник, а не только принятие команды TIS.
    /// false не отменяет уже выполненную текстовую замену: оркестратор сообщает частичный результат.
    @discardableResult
    public func switchTo(_ layout: Layout) -> Bool {
        guard currentLayout() != layout else { return true }
        guard let source = findSource(for: layout) else { return false }
        let status = TISSelectInputSource(source)
        #if DEBUG
        recordSelection(stage: "select", target: layout, status: status)
        #endif
        guard status == noErr else { return false }
        // Переключение не мгновенное — проверяем с паузой и повторяем раз.
        for _ in 0..<2 where currentLayout() != layout {
            Thread.sleep(forTimeInterval: 0.1)
            let retryStatus = TISSelectInputSource(source)
            #if DEBUG
            recordSelection(stage: "retry", target: layout, status: retryStatus)
            #endif
            _ = retryStatus
        }
        return currentLayout() == layout
    }

    #if DEBUG
    private func recordSelection(stage: String, target: Layout, status: OSStatus) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { TISSourceDiagnostics.recordSwitch(stage: stage, target: target, status: status) }
    }
    #endif

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
