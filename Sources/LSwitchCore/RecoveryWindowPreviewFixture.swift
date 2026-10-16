#if DEBUG
import CoreGraphics
import Foundation

/// Только счётчики fixture. Здесь нет raw events, текста или черновиков окна.
public struct RecoveryWindowPreviewReport: Sendable {
    public let fixtureOnly = true
    public let protection: RecoveryWindowProtection = .unverified
    public let eventCount: Int
    public let utf16Bytes: Int
    public let payloadDeleted: Bool
    public let isVisible: Bool
    public let revealCount: Int
    public let deletionRequests: Int
    public let confirmedDeletions: Int
    public let cancelledDeletions: Int
    public let hideCount: Int
    public let showCount: Int
}

/// DEBUG-мост использует настоящий coordinator, но не настоящий target/gate или захват ввода.
/// NSApplication должен быть создан вызывающим приложением до make().
@MainActor
public final class RecoveryWindowPreviewFixture {
    private let coordinator: RecoveryCoordinator
    private var reveals = 0
    private var requests = 0
    private var confirmations = 0
    private var cancellations = 0
    private var hides = 0
    private var shows = 0

    private init(coordinator: RecoveryCoordinator) { self.coordinator = coordinator }

    public static func make() -> RecoveryWindowPreviewFixture? {
        let coordinator = RecoveryCoordinator(gateFactory: RecoveryGateFactory(prepare: { scope in
            RecoveryGateCapability(scope: scope, isCurrent: { true })
        }))
        let ledger = ConversionSafetyLedger(generation: 1)
        guard let target = RecoveryProcessIdentity(processID: Int32.max, birthSeconds: 1, birthMicroseconds: 0),
              let admission = coordinator.reserve(operation: ledger.operation, target: target),
              let source = CGEventSource(stateID: .privateState) else { return nil }
        let buffer = InputEventBuffer()
        guard let token = buffer.beginHold(at: 0), let binding = admission.bindHold(token),
              populate(buffer, admission: admission, binding: binding, source: source),
              let seal = admission.seal(binding: binding), let batch = buffer.detach(token: token),
              let submitted = ledger.willSubmit(.selection, operation: ledger.operation),
              ledger.observe(.unknown, for: submitted),
              ledger.finish(operation: ledger.operation, text: .unchangedByOperation,
                            cleanup: .recoveryUnconfirmed, ordinaryRouteValid: false) != nil,
              let claim = ledger.claimInput(operation: ledger.operation) else { return nil }
        guard case .adopted = coordinator.adopt(batch, sealed: seal, claim: claim, reason: .cleanupUnconfirmed) else {
            return nil
        }
        return RecoveryWindowPreviewFixture(coordinator: coordinator)
    }

    public var metadata: RecoveryWindowMetadata? {
        guard let stored = coordinator.metadata else { return nil }
        return RecoveryWindowMetadata(
            recordIdentifier: stored.identifier, applicationName: "Тестовый редактор",
            counts: .init(events: stored.eventCount, utf16Bytes: stored.utf16Bytes),
            reason: .cleanupUnconfirmed, protection: .unverified
        )
    }

    public var actions: RecoveryWindowActions {
        RecoveryWindowActions(reveal: { [weak self] record in
            self?.reveal(record)
        }, requestDeletion: { [weak self] record in
            self?.requestDeletion(record)
        }, didHide: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record else { return }
            self.hides += 1
            self.coordinator.hide()
        })
    }

    public func show() {
        shows += 1
        coordinator.show()
    }

    public var quitActions: RecoveryQuitActions { coordinator.quitActions }

    public var report: RecoveryWindowPreviewReport {
        let stored = coordinator.metadata
        return .init(
            eventCount: stored?.eventCount ?? 0, utf16Bytes: stored?.utf16Bytes ?? 0,
            payloadDeleted: stored?.payloadDeleted ?? true, isVisible: stored?.isVisible ?? false,
            revealCount: reveals, deletionRequests: requests, confirmedDeletions: confirmations,
            cancelledDeletions: cancellations, hideCount: hides, showCount: shows
        )
    }

    private func reveal(_ record: UUID) -> RecoveryProjection? {
        guard coordinator.metadata?.identifier == record, let intent = coordinator.requestReveal(),
              coordinator.reveal(intent) else { return nil }
        reveals += 1
        return coordinator.revealedProjection
    }

    private func requestDeletion(_ record: UUID) -> RecoveryWindowDeletionRequest? {
        guard coordinator.metadata?.identifier == record, let intent = coordinator.requestDeletion() else { return nil }
        requests += 1
        return RecoveryWindowDeletionRequest(recordIdentifier: record, confirm: { [weak self] in
            guard let self, self.coordinator.metadata?.identifier == record,
                  self.coordinator.confirmDeletion(intent) == .deleted else { return false }
            self.confirmations += 1
            return true
        }, cancel: { [weak self] in
            guard let self, self.coordinator.metadata?.identifier == record,
                  self.coordinator.cancelDeletion(intent) == .stay else { return }
            self.cancellations += 1
        })
    }

    private struct FixtureKey {
        let text: String
        let type: CGEventType
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    private static func populate(
        _ buffer: InputEventBuffer, admission: PreparedRecoveryAdmission,
        binding: RecoveryHoldBinding, source: CGEventSource
    ) -> Bool {
        let keys = [
            FixtureKey(text: "Тест 😀", type: .keyDown, code: 0, flags: .maskNonCoalesced),
            FixtureKey(text: "Тест 😀", type: .keyUp, code: 0, flags: []),
            FixtureKey(text: "e\u{301}\u{A0}", type: .keyDown, code: 0, flags: []),
            FixtureKey(text: "c", type: .keyDown, code: 8, flags: .maskCommand),
            FixtureKey(text: "", type: .keyDown, code: 123, flags: []),
            FixtureKey(text: "é", type: .keyDown, code: 0, flags: .maskAlternate)
        ]
        for key in keys {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: key.code, keyDown: key.type == .keyDown
            ) else { return false }
            event.type = key.type
            event.flags = key.flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            let units = Array(key.text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            guard append(event, units: units.count, to: buffer, admission: admission, binding: binding) else {
                return false
            }
        }
        for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left
            ), append(event, units: 0, to: buffer, admission: admission, binding: binding) else { return false }
        }
        return true
    }

    private static func append(
        _ event: CGEvent, units: Int, to buffer: InputEventBuffer,
        admission: PreparedRecoveryAdmission, binding: RecoveryHoldBinding
    ) -> Bool {
        admission.admit(utf16Units: units, binding: binding) {
            buffer.intercept(type: event.type, event: event, at: 1)
        } == .accepted
    }
}
#endif
