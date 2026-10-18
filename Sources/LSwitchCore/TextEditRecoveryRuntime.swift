#if DEBUG
import ApplicationServices
import Darwin
import Foundation

/// Opt-in qualification только для явного собственного файла. Обычный runtime factory сюда не обращается.
@MainActor
public final class TextEditRecoveryRuntime {
    public let owner = ConversionRecoveryOwner()
    public var onStateChange: @MainActor () -> Void = {}
    public private(set) var diagnosticStage = TextEditRecoveryStage.idle.rawValue
    let identity = UUID()
    let eventTap: @MainActor () -> EventTapCore?
    let currentSafety: @MainActor () -> Bool
    let testDocument: URL?
    let faultMode: TextEditRecoveryFaultMode
    var attempt: TextEditRecoveryAttempt?
    var quitAuthorized = false
    var lastProfileReport: TextEditRecoveryProfileReport?
    var lastProfileInvocation: TextEditRecoveryInvocation?

    public init(
        testDocument: URL, faultMode: TextEditRecoveryFaultMode = .none,
        eventTap: @escaping @MainActor () -> EventTapCore?, currentSafety: @escaping @MainActor () -> Bool
    ) {
        self.testDocument = testDocument.isFileURL && testDocument.path.hasPrefix("/")
            ? testDocument.standardizedFileURL : nil
        self.eventTap = eventTap
        self.currentSafety = currentSafety
        self.faultMode = faultMode
    }

    public var faultReport: TextEditRecoveryFaultReport? { attempt?.fault?.report }

    public var status: TextEditRecoveryStatus {
        .init(hasPending: owner.hasPendingRecovery || owner.hasPendingTransport || attempt?.adapter?.hasPending == true,
              hasUnsettled: attempt.map {
                  $0.preparing || $0.finishing || !$0.invocationFinished || $0.adapter?.hasUnsettled == true
              } ?? false, metadataReady: metadata != nil)
    }

    public func beginInvocation() -> TextEditRecoveryInvocation? {
        guard attempt == nil, !owner.isOccupied, !quitAuthorized, currentSafety() else { return nil }
        guard attempt == nil, !owner.isOccupied, !quitAuthorized else { return nil }
        let token = TextEditRecoveryInvocation(runtime: identity)
        lastProfileReport = nil
        lastProfileInvocation = nil
        attempt = TextEditRecoveryAttempt(invocation: token)
        setStage(.invocation)
        return token
    }

    public func makeSession(_ context: ConversionRecoveryContext) async -> ConversionRecoverySession? {
        guard let attempt, !attempt.factoryEntered, !attempt.invocationFinished,
              attempt.interruption == nil, context.bundleID == "com.apple.TextEdit", testDocument != nil,
              currentSafety(), context.isCurrent(), let tap = eventTap(), tap.state == .running else { return nil }
        guard isLive(attempt), !attempt.factoryEntered else { return nil }
        attempt.factoryEntered = true
        attempt.preparing = true
        defer { attempt.preparing = false; onStateChange() }
        attempt.fault = faultMode == .missingAfterSelection ? TextEditRecoveryFaultFixture() : nil
        setStage(.profile)
        guard let prepared = prepareDriver(context, fault: attempt.fault), isLive(attempt) else { return nil }
        attempt.profile = prepared.profile
        let ledger = prepared.ledger
        let driver = prepared.driver
        let scope = driver.bridge.capturedScope
        attempt.driver = driver
        setStage(.driver)
        guard await driver.start(), self.attempt === attempt, attempt.interruption == nil,
              !Task.isCancelled, currentSafety(), context.isCurrent(), eventTap() === tap,
              isLive(attempt) else { return nil }
        setStage(.logical)
        guard let lease = await tap.beginProcessingLease(scope: scope) else { return nil }
        attempt.tap = tap
        attempt.lease = lease
        guard self.attempt === attempt, attempt.interruption == nil, currentSafety(), context.isCurrent(),
              eventTap() === tap, let arm = tap.prepareProcessingArm(lease), isLive(attempt) else { return nil }
        let logical = TextEditRecoveryLogicalLease(
            prepared: arm, isCurrent: { tap.processingLeaseIsCurrent(lease) },
            drain: { await tap.drainPendingEvents() },
            finish: { disposition, actions in
                await tap.finishProcessingLease(lease, disposition: disposition, actions: actions)
            }
        )
        setStage(.reserve)
        guard let resources = makeResources(ledger: ledger, driver: driver, logical: logical) else { return nil }
        let adapter = makeAdapter(resources, context: context, attempt: attempt)
        attempt.adapter = adapter
        guard let session = ConversionRecoverySession(
            context: context, ledger: ledger, allowedMechanisms: [.accessibility], adapter: adapter,
            boundAXEngine: prepared.engine
        ) else { adapter.retainBeforeSession(); return nil }
        attempt.session = session
        setStage(.registered)
        guard await adapter.arm(), self.attempt === attempt, attempt.interruption == nil,
              currentSafety(), context.isCurrent(), isLive(attempt) else {
            session.retainIfUnfinished()
            return session
        }
        setStage(.armed)
        return session
    }

    private func isLive(_ expected: TextEditRecoveryAttempt) -> Bool {
        attempt === expected && !expected.invocationFinished && expected.interruption == nil
            && !quitAuthorized && !Task.isCancelled
    }

    private func makeAdapter(
        _ resources: TextEditRecoveryAdapterResources, context: ConversionRecoveryContext,
        attempt: TextEditRecoveryAttempt
    ) -> TextEditRecoveryAdapter {
        let capture = resources.capture
        attempt.fault?.bind(deadline: resources.logical.prepared.deadline, isCurrent: { [weak capture] in
            capture?.isCurrent == true && resources.logical.isCurrent() && context.isCurrent()
        }, counters: { resources.capture.attachment.counters })
        return TextEditRecoveryAdapter(
            resources: resources, contextIsCurrent: context.isCurrent,
            currentSafety: { [weak self, weak attempt] in
                guard let self, let attempt else { return false }
                guard self.attempt === attempt, attempt.interruption == nil, self.currentSafety() else { return false }
                return self.attempt === attempt && attempt.interruption == nil
            }, changed: { [weak self] in self?.adapterChanged() },
            validationScope: TextEditRecoveryValidationScope(runtime: self, attempt: attempt)
        )
    }

    private func prepareDriver(
        _ context: ConversionRecoveryContext, fault: TextEditRecoveryFaultFixture?
    ) -> TextEditRecoveryPreparation? {
        guard let prepared = prepareProfile(fault), let sender = SystemProcessIdentity.read(processID: getpid()) else {
            return nil
        }
        let ledger = ConversionSafetyLedger(generation: context.generation, profile: prepared.profile.binding)
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: prepared.profile.binding.target)
        guard let gate = RecipientGateState(scope: scope), let bridge = RecoveryRecipientProbeBridge(
            sender: sender, target: scope.target, ledger: ledger, gate: gate
        ), let driver = RecipientTapDriver(bridge: bridge) else { return nil }
        return .init(ledger: ledger, driver: driver, profile: prepared.profile,
                     engine: AXTextConverter(access: prepared.access, observationProfile: prepared.profile))
    }

    private func makeResources(
        ledger: ConversionSafetyLedger, driver: RecipientTapDriver, logical: TextEditRecoveryLogicalLease
    ) -> TextEditRecoveryAdapterResources? {
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            guard scope == driver.bridge.capturedScope, driver.permitsCaptureReservation else { return nil }
            return .init(scope: scope, isCurrent: { driver.permitsCaptureReservation })
        }))
        let router = RecoveryCaptureRouter(bypassRawProcessing: true, acceptsRecipientInput: true)
        guard let admission = coordinator.reserve(operation: ledger.operation, target: logical.prepared.scope.target),
              let operation = RecoveryOperation.prepare(
                ledger: ledger, admission: admission, tapIdentifier: router.identifier, at: logical.prepared.startedAt,
                handoverFactory: .init(prepare: { scope, identifier in
                    .init(operationScope: scope, tapIdentifier: identifier,
                          protecting: { _, body in driver.withProtection(body) })
                })
              ) else { return nil }
        let attachment = RecoveryCaptureAttachment(port: operation.capturePort, policy: .recipientInput,
                                                   ownMarker: { driver.bridge.owns(senderPID: $0, marker: $1) })
        guard router.attach(attachment), let capture = RecipientOrdinaryCapture(
            router: router, attachment: attachment, scope: logical.prepared.scope
        ) else { return nil }
        attachment.scheduleExpiry()
        return .init(ledger: ledger, coordinator: coordinator, driver: driver, operation: operation,
                     capture: capture, logical: logical)
    }

    private func prepareProfile(
        _ fault: TextEditRecoveryFaultFixture?
    ) -> (profile: AXObservationProfile, access: any AXTextAccess)? {
        guard let testDocument, let target = InputSafety.captureTarget() else { return nil }
        let access = SystemAXTextAccess()
        let system = AXProfileEnvironment.textEditCandidate()
        let guarded = AXProfileEnvironment(
            activeSource: system.activeSource, focusedElement: system.focusedElement,
            isProtected: system.isProtected, context: { element in
                guard let context = system.context(element), let document = URL(string: context.document),
                      document.isFileURL, document.standardizedFileURL == testDocument else { return nil }
                return context
            }, snapshot: { element, canRead in
                if let fault { return fault.snapshot(element, canRead: canRead, original: system.snapshot) }
                return system.snapshot(element, canRead)
            }, foregroundProcessID: system.foregroundProcessID,
            boundedSnapshot: fault == nil ? system.boundedSnapshot : nil
        )
        guard let profile = AXObservationProfile.prepareTextEdit(element: target.element, environment: guarded),
              profile.binding.target.processID == target.capturedApplicationPID else { return nil }
        if let fault { return (profile, TextEditRecoveryFaultAccess(original: access, fixture: fault)) }
        return (profile, access)
    }

    func setStage(_ stage: TextEditRecoveryStage) { diagnosticStage = stage.rawValue; onStateChange() }
    func adapterChanged() {
        if attempt?.adapter?.adopted == true { setStage(.retained) } else { onStateChange() }
    }
}

@MainActor
private struct TextEditRecoveryPreparation {
    let ledger: ConversionSafetyLedger
    let driver: RecipientTapDriver
    let profile: AXObservationProfile
    let engine: any ConversionEngine
}

@MainActor
final class TextEditRecoveryAttempt {
    let invocation: TextEditRecoveryInvocation
    var factoryEntered = false
    var preparing = false
    var finishing = false
    var invocationFinished = false
    var interruption: TextEditRecoveryInterruption?
    var driver: (any TextEditRecoveryDriver)?
    var tap: EventTapCore?
    var lease: EventProcessingLease?
    var adapter: TextEditRecoveryAdapter?
    var session: ConversionRecoverySession?
    var fault: TextEditRecoveryFaultFixture?
    var profile: AXObservationProfile?
    var logicalFailure: EventProcessingInvalidation?

    init(invocation: TextEditRecoveryInvocation) { self.invocation = invocation }
}
#endif
