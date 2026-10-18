#if DEBUG
import ApplicationServices
import Darwin
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class AXCombinedProfileControls {
    var hostSafety: () -> Bool = { true }
    var onContext: () -> Void = {}
    var foreground: Int32? = getpid()
    var foregroundRead: (() -> Int32?)?
    var additionalValid = true
    var fullTargetChecks = 0
    var contextReads = 0
    var foregroundReads = 0

    func checkFullTarget() -> Bool { fullTargetChecks += 1; return true }
    func readForeground() -> Int32? {
        foregroundReads += 1
        if let foregroundRead { return foregroundRead() }
        return foreground
    }
}

/// Настоящие Profile/Session/lease/native-state; только AX payload и post — модель, без системного ввода.
@MainActor
final class AXCombinedProfileFixture {
    let editor: AXProfileFixture
    let runtime: TextEditRecoveryRuntime
    let attempt: TextEditRecoveryAttempt
    let converter: Converter
    let profile: AXObservationProfile
    let ledger: ConversionSafetyLedger
    let native: TextEditRecoveryAdapterFixture
    let session: ConversionRecoverySession
    let request: ConversionRequest
    let capability: AXProfileRequestValidation
    let controls = AXCombinedProfileControls()

    init() throws {
        let editor = try AXProfileFixture()
        editor.process = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
        self.editor = editor
        let controls = self.controls
        let profile = try Self.makeProfile(editor, controls: controls)
        self.profile = profile
        let runtime = TextEditRecoveryRuntime(testDocument: URL(fileURLWithPath: "/fixture/profile.txt"),
                                              eventTap: { nil }, currentSafety: { true })
        self.runtime = runtime
        XCTAssertNotNil(runtime.beginInvocation())
        let attempt = try XCTUnwrap(runtime.attempt)
        self.attempt = attempt
        let converter = TrackedConverterFixture().converter
        self.converter = converter
        let ledger = ConversionSafetyLedger(generation: converter.revision, profile: profile.binding)
        self.ledger = ledger
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let native = try TextEditRecoveryAdapterFixture(
            ledger: ledger, validationScope: .init(runtime: runtime, attempt: attempt), startedAt: startedAt,
            currentSafety: { controls.hostSafety() }, contextIsCurrent: { controls.checkFullTarget() }
        )
        self.native = native
        let context = ConversionRecoveryContext(
            bundleID: "com.apple.TextEdit", sourceLayout: .english, generation: converter.revision,
            startedAt: startedAt, admission: try XCTUnwrap(runtime.owner.reserve()),
            isCurrent: { controls.checkFullTarget() }, canCleanup: { controls.checkFullTarget() },
            revisionFence: .init(converter: converter, generation: converter.revision)
        )
        let session = try XCTUnwrap(ConversionRecoverySession(
            context: context, ledger: ledger, allowedMechanisms: [.accessibility], adapter: native.adapter,
            boundAXEngine: AXTextConverter(access: editor.access, observationProfile: profile)
        ))
        self.session = session
        attempt.session = session
        attempt.adapter = native.adapter
        request = Self.makeRequest(session)
        capability = try XCTUnwrap(request.profileValidation)
    }

    private static func makeProfile(
        _ editor: AXProfileFixture, controls: AXCombinedProfileControls
    ) throws -> AXObservationProfile {
        let original = editor.environment
        let environment = AXProfileEnvironment(
            activeSource: original.activeSource, focusedElement: original.focusedElement,
            isProtected: original.isProtected, context: { element in
                controls.contextReads += 1
                controls.onContext()
                return original.context(element)
            }, snapshot: original.snapshot, foregroundProcessID: { controls.readForeground() }
        )
        return try XCTUnwrap(AXObservationProfile.prepareTextEdit(
            element: editor.access.model.element, environment: environment))
    }

    private static func makeRequest(_ session: ConversionRecoverySession) -> ConversionRequest {
        let diagnostics = ConversionDiagnostics(bundleID: "com.apple.TextEdit", triggerTimestamp: nil,
                                                attempt: 1, automatic: true, now: { 1 }, emit: { _ in })
        return .init(canonical: .init(expectedWord: "ghbdtn", trailingText: " ", replacement: nil,
                                     sourceLayout: .english, useSelection: false, diagnostics: diagnostics),
                     session: session)
    }

    func arm() async {
        let armed = await native.adapter.arm()
        XCTAssertTrue(armed)
    }

    func bind(_ request: ConversionRequest? = nil) -> Bool {
        let request = request ?? self.request
        return profile.bind(to: editor.access.model.element, ledger: ledger,
                            isValid: request.isValid, validation: request.profileValidation)
    }
}
#endif
