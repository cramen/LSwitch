import AppKit
import Foundation

/// Одна транзакция clipboard: выделение создаётся один раз, хвост не конвертируется,
/// а снимок восстанавливается только пока буфер принадлежит этой операции.
@MainActor
public final class ClipboardConverter: ConversionEngine {

    public struct Configuration: Sendable {
        public var initialReadDelay: TimeInterval = 0.03
        public var writeDelay: TimeInterval = 0.02
        public var postPasteDelay: TimeInterval = 0.15
        public var preCopyDelay: TimeInterval = 0.02
        public var maxAttempts = 3

        #if DEBUG
        /// Проверка резервного Copy-пути без изменения последующих AX-проверок.
        public var forceCopyForAcceptance = false
        #endif

        var allowsSnapshotPath: Bool {
            #if DEBUG
            return !forceCopyForAcceptance
            #else
            return true
            #endif
        }

        public init() {}
    }

    public enum Outcome: Equatable {
        case success(original: String, converted: String)
        case copyFailed
    }

    private let configuration: Configuration
    private let environment: ClipboardEnvironment
    private let transform: (@Sendable (String) -> String)?
    private var busy = false

    public init(
        configuration: Configuration = Configuration(),
        transform: (@Sendable (String) -> String)? = nil
    ) {
        self.configuration = configuration
        self.environment = .live(pasteboard: .general)
        self.transform = transform
    }

    init(configuration: Configuration = Configuration(), environment: ClipboardEnvironment) {
        self.configuration = configuration
        self.environment = environment
        self.transform = nil
    }

    #if DEBUG
    public convenience init(acceptanceConfiguration: Configuration, keyboardOnly: Bool) {
        self.init(
            configuration: acceptanceConfiguration,
            environment: .live(pasteboard: .general, keyboardOnly: keyboardOnly)
        )
    }
    #endif

    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        await perform(request, environment: environment)
    }

    /// Совместимость с диагностическими клиентами раннего прототипа.
    @discardableResult
    public func convertSelection(
        expectedWord: String? = nil,
        pasteboard: NSPasteboard = .general
    ) async -> Outcome {
        let request = ConversionRequest(expectedWord: expectedWord)
        let result = await perform(request, environment: .live(pasteboard: pasteboard))
        guard case .success(let receipt) = result else { return .copyFailed }
        return .success(original: receipt.original, converted: receipt.converted)
    }

    private func perform(
        _ request: ConversionRequest,
        environment: ClipboardEnvironment
    ) async -> ConversionResult {
        guard !busy else { return .blocked }
        busy = true
        defer { busy = false }
        let transaction = ClipboardTransaction(
            request: request,
            configuration: configuration,
            environment: environment,
            transform: transform
        )
        return await transaction.run()
    }
}
