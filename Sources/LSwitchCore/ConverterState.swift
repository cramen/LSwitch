import Foundation

public enum ConversionMode: String, Sendable {
    case accessibility
    case clipboard
}

@MainActor
public struct AXConversionEngine: ConversionEngine {
    public init() {}
    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        await AXTextConverter().perform(request)
    }
}

@MainActor
public struct ClipboardConversionEngine: ConversionEngine {
    private let localProfiles: LocalAppProfiles?
    public init(localProfiles: LocalAppProfiles? = nil) { self.localProfiles = localProfiles }
    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        await ClipboardConverter(localProfiles: localProfiles).perform(request)
    }
}

/// Точный оригинал и контекст последней подтверждённой замены.
public struct UndoRecord: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let layoutBefore: Layout
    public let timestamp: Date
    public let trailingText: String
    public let bundleID: String?

    public init(
        original: String, converted: String, layoutBefore: Layout, timestamp: Date,
        trailingText: String = "", bundleID: String? = nil
    ) {
        self.original = original
        self.converted = converted
        self.layoutBefore = layoutBefore
        self.timestamp = timestamp
        self.trailingText = trailingText
        self.bundleID = bundleID
    }
}

/// Используется оркестратором и UI только на главном потоке.
public final class UndoStore {
    public var window: TimeInterval = 3
    private var record: UndoRecord?
    private let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) { self.now = now }
    public func save(_ record: UndoRecord) { self.record = record }
    public func invalidate() { record = nil }

    public func pendingUndo() -> UndoRecord? {
        guard let record else { return nil }
        guard now().timeIntervalSince(record.timestamp) <= window else {
            self.record = nil
            return nil
        }
        return record
    }
}
