import ApplicationServices
import Foundation

/// Opt-in provider наблюдений B. Не является factory системного gate или renderer ACK.
@MainActor
final class AXObservationProfile {
    let binding: ConversionSafetyProfileBinding
    private let element: AXUIElement
    private let captured: AXProfileContext
    private let environment: AXProfileEnvironment
    private let source: UnicodeInputSource
    private var operation: ConversionSafetyOperationToken?
    private var requestIsValid: () -> Bool = { false }

    private init(
        element: AXUIElement, captured: AXProfileContext, source: UnicodeInputSource, environment: AXProfileEnvironment
    ) {
        self.element = element
        self.captured = captured
        self.environment = environment
        self.source = source
        binding = .init(profile: .textEditAX119MacOS145, target: captured.process,
                        documentIdentity: UUID(), elementIdentity: UUID(), windowIdentity: UUID())
    }

    static func prepareTextEdit(element: AXUIElement, environment: AXProfileEnvironment) -> AXObservationProfile? {
        guard !Task.isCancelled, let source = environment.activeSource(), !environment.isProtected(element),
              let focused = environment.focusedElement(), CFEqual(focused, element),
              let captured = environment.context(element), captured.isSupported,
              !environment.isProtected(element), let checked = environment.context(element), captured.matches(checked),
              let finalFocus = environment.focusedElement(), CFEqual(finalFocus, element),
              environment.activeSource() == source, !Task.isCancelled else {
            return nil
        }
        return AXObservationProfile(element: element, captured: captured, source: source, environment: environment)
    }

    func bind(to element: AXUIElement, ledger: ConversionSafetyLedger, isValid: @escaping () -> Bool) -> Bool {
        guard ledger.profileBinding == binding, CFEqual(self.element, element),
              operation == nil || operation == ledger.operation else { return false }
        operation = ledger.operation
        requestIsValid = isValid
        return isCurrent(ledger: ledger)
    }

    func isCurrent(ledger: ConversionSafetyLedger) -> Bool {
        guard !Task.isCancelled else { return fault(.cancelled, ledger: ledger) }
        guard operation == ledger.operation, ledger.profileBinding == binding,
              ledger.decision == nil, !ledger.hasProfileFault else { return false }
        guard requestIsValid(), environment.activeSource() == source, !environment.isProtected(element),
              let focused = environment.focusedElement(), CFEqual(focused, element),
              let context = environment.context(element), captured.matches(context),
              !environment.isProtected(element),
              let finalFocus = environment.focusedElement(), CFEqual(finalFocus, element),
              environment.activeSource() == source, requestIsValid(), !Task.isCancelled else {
            return fault(Task.isCancelled ? .cancelled : .contextChanged, ledger: ledger)
        }
        return ledger.decision == nil && !ledger.hasProfileFault
    }

    /// Ticket создаётся до fresh read, принимается после последнего внешнего guard.
    func observe(
        step: ConversionSafetyProfileStep, reply: AXWriteReply?, expected: AXProfileExpectedState,
        ledger: ConversionSafetyLedger
    ) -> Bool {
        guard isCurrent(ledger: ledger), reply == nil || reply?.status == .success,
              let ticket = ledger.beginProfileObservation(step: step, submission: reply?.submission, binding: binding)
        else { return fault(.snapshotMismatch, ledger: ledger) }
        guard read(expected: expected, ledger: ledger) != nil else { return false }
        guard ledger.observeUnderProfile(ticket, binding: binding) else {
            return fault(.snapshotMismatch, ledger: ledger)
        }
        return true
    }

    func read(expected: AXProfileExpectedState?, ledger: ConversionSafetyLedger) -> AXProfileSnapshot? {
        guard isCurrent(ledger: ledger) else { return nil }
        var denied = false
        let snapshot = environment.snapshot(element) {
            guard !denied, self.isCurrent(ledger: ledger) else { denied = true; return false }
            return true
        }
        guard !denied, isCurrent(ledger: ledger) else { return nil }
        guard let snapshot else { _ = fault(.snapshotUnavailable, ledger: ledger); return nil }
        let matches = expected.map {
            snapshot.text.utf16.elementsEqual($0.text.utf16) && $0.selections.contains(snapshot.selection)
        } ?? true
        guard snapshot.isComplete, matches else {
            _ = fault(.snapshotMismatch, ledger: ledger)
            return nil
        }
        return snapshot
    }

    @discardableResult
    private func fault(_ reason: ConversionSafetyProfileFault, ledger: ConversionSafetyLedger) -> Bool {
        ledger.recordProfileFault(reason, operation: ledger.operation)
        return false
    }
}
