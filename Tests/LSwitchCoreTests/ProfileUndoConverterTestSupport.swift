#if DEBUG
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class ProfileUndoRecordingEngine: ConversionEngine {
    let engine: AXTextConverter
    var requests: [ConversionRequest] = []
    var wrap: (ConversionReceipt) -> ConversionReceipt = { $0 }

    init(_ engine: AXTextConverter) { self.engine = engine }
    func perform(_ request: ConversionRequest) async -> ConversionResult {
        requests.append(request)
        let result = await engine.perform(request)
        if case .success(let receipt) = result { return .success(wrap(receipt)) }
        return result
    }
}

/// Полный Converter/Session/profile/native custody flow; AX и delivery остаются memory-only.
@MainActor
final class ProfileUndoConverterFixture {
    let editor: AXProfileFixture
    let runtime = TextEditRecoveryRuntime(testDocument: URL(fileURLWithPath: "/fixture/undo.txt"),
                                          eventTap: { nil }, currentSafety: { true })
    let rules = AppRules(defaults: UserDefaults(suiteName: "profile-undo-\(UUID().uuidString)") ?? .standard)
    let undoStore = UndoStore()
    var layout = Layout.english
    var sessions: [ConversionRecoverySession] = []
    var engines: [ProfileUndoRecordingEngine] = []
    var natives: [TextEditRecoveryAdapterFixture] = []
    var customTarget: (() -> Bool)?

    init(_ text: String) throws {
        editor = try AXProfileFixture(text)
        editor.process = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
    }

    lazy var converter = Converter(currentLayout: { [weak self] in self?.layout }, switchLayout: { [weak self] target in
        guard let self else { return false }
        self.layout = target
        self.editor.activeSource = .init(identifier: target == .english
            ? "com.apple.keylayout.ABC" : "com.apple.keylayout.Russian", isKeyboardLayout: true)
        return true
    }, appRules: rules, undoStore: undoStore, frontmostBundleID: { "com.apple.TextEdit" },
        makeAXEngine: { StubEngine() }, makeClipboardEngine: { StubEngine() },
        recoverySessionFactory: { [weak self] context in await self?.makeSession(context) },
        recoveryOwner: runtime.owner, captureContext: { { true } })

    func perform() async throws -> Converter.Outcome {
        let invocation = try XCTUnwrap(runtime.beginInvocation())
        let outcome = await converter.trigger()
        _ = await runtime.finishInvocation(invocation, outcome: outcome,
            actions: .init(applyOutcome: { _ in }, reset: {}, consume: { _ in }))
        return outcome
    }

    private func makeSession(_ context: ConversionRecoveryContext) async -> ConversionRecoverySession? {
        guard let attempt = runtime.attempt else { return nil }
        var environment = editor.environment
        environment.foregroundProcessID = { getpid() }
        guard let profile = AXObservationProfile.prepareTextEdit(element: editor.access.model.element,
                                                                 environment: environment) else { return nil }
        let ledger = ConversionSafetyLedger(generation: context.generation, profile: profile.binding)
        guard let native = try? TextEditRecoveryAdapterFixture(
            ledger: ledger, validationScope: .init(runtime: runtime, attempt: attempt),
            startedAt: DispatchTime.now().uptimeNanoseconds
        ) else { return nil }
        let engine = ProfileUndoRecordingEngine(AXTextConverter(access: editor.access, observationProfile: profile))
        if let customTarget { engine.wrap = { $0.checkingTarget(customTarget) } }
        guard let session = ConversionRecoverySession(context: context, ledger: ledger,
            allowedMechanisms: [.accessibility], adapter: native.adapter, boundAXEngine: engine) else { return nil }
        attempt.session = session
        attempt.adapter = native.adapter
        attempt.profile = profile
        let driver = native.driver
        driver.onWake = { [weak driver] in try? driver?.deliverWake() }
        sessions.append(session)
        engines.append(engine)
        natives.append(native)
        guard await native.adapter.arm() else { session.retainIfUnfinished(); return session }
        return session
    }
}
#endif
