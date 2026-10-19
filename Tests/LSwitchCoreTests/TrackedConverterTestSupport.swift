import Foundation
@testable import LSwitchCore
import XCTest

/// Модель владения: нет CGEvent, post, TCC или настоящего transport permit.
@MainActor
final class TrackedConversionAdapter: ConversionRecoveryAdapter {
    var isCaptureValid = false
    var activationAllowed = true
    var activations = 0
    var onActivate: () -> Void = {}
    private var routeCurrent = true
    var onRouteCheck: () -> Void = {}
    var isOrdinaryRouteCurrent: Bool {
        get { onRouteCheck(); return routeCurrent }
        set { routeCurrent = newValue }
    }
    var prepareAllowed = true
    var commitAllowed = true
    var failAfterClaim = false
    var acceptWithoutClaim = false
    var queued = 2
    var delivered = 0
    var retentions = 0
    var acceptedClaim: ConversionSafetyInputClaim?
    var retainedClaim: ConversionSafetyInputClaim?
    var corrections: [ConversionRecoveryLayoutTransition] = []
    var drain: () async -> Void = {}
    var onPrepare: () -> Void = {}
    var onCommit: () -> Void = {}
    var beforeClaim: () -> Void = {}
    var onAccepted: () -> Void = {}
    var completesImmediately = true
    private(set) var transport: ConversionOrdinaryTransport?
    private var completed = false
    let record: (String) -> Void

    init(record: @escaping (String) -> Void) { self.record = record }
    func activateCapture() -> Bool {
        activations += 1
        onActivate()
        isCaptureValid = activationAllowed
        return activationAllowed
    }
    func beginMutation() -> Bool { record("mutation"); return isCaptureValid }
    func drainPendingInput() async { record("drain"); await drain() }
    func prepareOrdinary() -> Bool {
        record("prepareDelivery")
        onPrepare()
        return prepareAllowed
    }
    func commitOrdinary(
        correction: ConversionRecoveryLayoutTransition?, claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> ConversionOrdinaryAcceptance {
        record("commit")
        beforeClaim()
        if acceptWithoutClaim { return .accepted(ConversionOrdinaryTransport()) }
        guard commitAllowed, let claim = claimOwnership() else { return .refused }
        acceptedClaim = claim
        record("claim")
        if let correction { corrections.append(correction); record("correction") }
        onCommit()
        guard !failAfterClaim else { return .refused }
        let accepted = ConversionOrdinaryTransport()
        transport = accepted
        isCaptureValid = false
        onAccepted()
        if completesImmediately { completeTransport(.locallyDispatched) }
        return .accepted(accepted)
    }
    func completeTransport(_ result: ConversionOrdinaryTransportResult) {
        guard !completed, let transport else { return }
        completed = true
        if result == .locallyDispatched {
            delivered += queued
            queued = 0
            record("deliver")
        }
        XCTAssertTrue(transport.complete(result))
    }
    func retainForRecovery(claim: ConversionSafetyInputClaim?) {
        retainedClaim = claim
        retentions += 1
        record("retain")
    }
}

@MainActor
final class TrackedConverterFixture {
    let accessibility = StubEngine()
    let clipboard = StubEngine()
    let unicode = StubEngine()
    let undoStore = UndoStore()
    let owner = ConversionRecoveryOwner()
    let rules = AppRules(defaults: UserDefaults(suiteName: "tracked-\(UUID().uuidString)") ?? .standard)
    var actions: [String] = []
    var sessions: [ConversionRecoverySession] = []
    var adapters: [TrackedConversionAdapter] = []
    var ledgers: [ConversionSafetyLedger] = []
    var mechanisms: [ConversionDiagnostics.Mechanism] = [.accessibility, .clipboard]
    var profile: ConversionSafetyProfileBinding?
    var boundAXEngine: (any ConversionEngine)?
    var latestContext: ConversionRecoveryContext?
    var layout: Layout? = .english
    var safe = true
    var factoryAvailable = true
    var factoryCalls = 0
    var localProfiles: LocalAppProfiles?
    var clipboardPreferred = false
    var unicodePreferred = false
    var layoutAccepted = true
    var applyLayout = true
    var configureAdapter: (TrackedConversionAdapter) -> Void = { _ in }
    var beforeFactory: () async -> Void = {}
    var afterFactory: () async -> Void = {}
    var onSwitch: () -> Void = {}
    var onSound: () -> Void = {}
    var onLayoutRead: () -> Void = {}

    lazy var converter = makeConverter()

    func makeConverter(includeOwner: Bool = true) -> Converter {
        Converter(
        currentLayout: { [weak self] in self?.onLayoutRead(); return self?.layout },
        switchLayout: { [weak self] target in
            guard let self else { return false }
            self.actions.append("layout")
            self.onSwitch()
            if self.layoutAccepted && self.applyLayout { self.layout = target }
            return self.layoutAccepted
        }, appRules: rules, undoStore: undoStore, frontmostBundleID: { "com.example.TextEdit" },
        prefersClipboard: { [weak self] _ in self?.clipboardPreferred == true },
        localProfiles: localProfiles,
        makeAXEngine: { [accessibility] in accessibility },
        makeClipboardEngine: { [clipboard] in clipboard },
        makeUnicodeEngine: { [weak self] _ in self?.unicodePreferred == true ? self?.unicode : nil },
        recoverySessionFactory: { [weak self] context in
            guard let self else { return nil }
            await self.beforeFactory()
            let session = self.makeSession(context)
            await self.afterFactory()
            return session
        },
        recoveryOwner: includeOwner ? owner : nil,
        captureContext: { [weak self] in { self?.safe == true } },
        beginInputHold: { [weak self] in self?.actions.append("legacyHold"); return true },
        endInputHold: { [weak self] in self?.actions.append("legacyRelease") },
        onLayoutSwitched: { [weak self] _, _, _ in self?.actions.append("legacyCorrection") },
        onConverted: { [weak self] in self?.actions.append("sound"); self?.onSound() }
        )
    }

    func makeSession(_ context: ConversionRecoveryContext) -> ConversionRecoverySession? {
        factoryCalls += 1
        guard factoryAvailable else { return nil }
        latestContext = context
        let ledger = profile.map { ConversionSafetyLedger(generation: context.generation, profile: $0) }
            ?? ConversionSafetyLedger(generation: context.generation)
        let adapter = TrackedConversionAdapter { [weak self] in self?.actions.append($0) }
        configureAdapter(adapter)
        guard let session = ConversionRecoverySession(
            context: context, ledger: ledger, allowedMechanisms: mechanisms, adapter: adapter,
            boundAXEngine: boundAXEngine
        ) else { return nil }
        sessions.append(session)
        ledgers.append(ledger)
        adapters.append(adapter)
        actions.append("trackedHold")
        return session
    }

    func succeed(_ engine: StubEngine, original: String = "ghbdtn", converted: String = "привет") {
        engine.handler = { request in
            XCTAssertTrue(request.beginMutation())
            guard let ledger = request.safetyLedger,
                  let token = ledger.willSubmit(.text, operation: ledger.operation) else { return .failed }
            XCTAssertTrue(ledger.observe(.adapterReturned(true), for: token))
            if let binding = ledger.profileBinding {
                guard let step = ledger.beginProfileObservation(step: .text, submission: token, binding: binding),
                      ledger.observeUnderProfile(step, binding: binding),
                      let final = ledger.beginProfileObservation(step: .finalState, binding: binding),
                      ledger.observeUnderProfile(final, binding: binding) else { return .failed }
            } else { XCTAssertTrue(ledger.observe(.receiverCompleted, for: token)) }
            guard let cleanup = ledger.beginCleanupObservation(operation: ledger.operation) else { return .failed }
            XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: cleanup))
            return .success(.init(original: original, converted: converted, trailingText: request.trailingText))
        }
    }
}
