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
    private let diagnostics = AXProfileDiagnostics()
    private weak var diagnosticLedger: ConversionSafetyLedger?
    private var operation: ConversionSafetyOperationToken?
    private var requestIsValid: () -> Bool = { false }
    private var requestValidation: AXProfileRequestValidation?

    var diagnosticReport: AXProfileDiagnosticReport { diagnostics.report(fault: diagnosticLedger?.profileFault) }

    func receiptTarget() -> AXProfileReceiptTarget {
        .init(element: element, captured: captured, environment: environment)
    }

    func boundElementMatches(_ element: AXUIElement) -> Bool { CFEqual(self.element, element) }

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

    func bind(
        to element: AXUIElement, ledger: ConversionSafetyLedger, isValid: @escaping () -> Bool,
        validation: AXProfileRequestValidation? = nil
    ) -> Bool {
        guard ledger.profileBinding == binding, CFEqual(self.element, element),
              operation == nil || operation == ledger.operation else { return false }
        if let validation {
            guard validation.binding == binding, validation.operation == ledger.operation,
                  validation.matches(ledger: ledger) else { return false }
        }
        if operation != nil, requestValidation !== validation { return false }
        operation = ledger.operation
        diagnosticLedger = ledger
        requestIsValid = isValid
        requestValidation = validation
        return isCurrent(ledger: ledger)
    }

    func isCurrent(ledger: ConversionSafetyLedger) -> Bool {
        guard !Task.isCancelled else { return fault(.cancelled, ledger: ledger) }
        guard operation == ledger.operation, ledger.profileBinding == binding,
              ledger.decision == nil, !ledger.hasProfileFault else { return false }
        let token: AXProfileValidationToken?
        if let requestValidation {
            token = diagnostics.measure(.requestIsValid) {
                requestValidation.begin(binding: binding, operation: ledger.operation)
            }
            guard token != nil else {
                return fault(Task.isCancelled ? .cancelled : .contextChanged, ledger: ledger)
            }
        } else {
            token = nil
            guard diagnostics.measure(.requestIsValid, { requestIsValid() }) else {
                return fault(Task.isCancelled ? .cancelled : .contextChanged, ledger: ledger)
            }
        }
        guard targetIsCurrent(checkForeground: requestValidation != nil) else {
            return fault(Task.isCancelled ? .cancelled : .contextChanged, ledger: ledger)
        }
        let closed = diagnostics.measure(.requestIsValid) {
            if let requestValidation, let token { return requestValidation.finish(token) }
            return requestIsValid()
        }
        guard closed, !Task.isCancelled else {
            return fault(Task.isCancelled ? .cancelled : .contextChanged, ledger: ledger)
        }
        return ledger.decision == nil && !ledger.hasProfileFault
    }

    private func targetIsCurrent(checkForeground: Bool) -> Bool {
        guard !checkForeground || foregroundMatches(),
              diagnostics.measure(.source, { environment.activeSource() }) == source,
              checkForeground || initialFocusIsCurrent(),
              let context = diagnostics.measure(.context, { environment.context(element) }), captured.matches(context),
              requestValidation?.undoTarget?.matches(element: element, context: context) != false,
              !diagnostics.measure(.protectedField, { environment.isProtected(element) }),
              let finalFocus = diagnostics.measure(.focus, { environment.focusedElement() }),
              CFEqual(finalFocus, element), diagnostics.measure(.source, { environment.activeSource() }) == source,
              !checkForeground || foregroundMatches() else { return false }
        return true
    }

    /// Generic callbacks сохраняют прежнюю начальную проверку. Canonical читает здесь только metadata.
    private func initialFocusIsCurrent() -> Bool {
        guard !diagnostics.measure(.protectedField, { environment.isProtected(element) }),
              let focused = diagnostics.measure(.focus, { environment.focusedElement() }) else { return false }
        return CFEqual(focused, element)
    }

    private func foregroundMatches() -> Bool {
        diagnostics.measure(.foreground, { environment.foregroundProcessID() }) == captured.process.processID
    }

    /// Ticket создаётся до fresh read, принимается после последнего внешнего guard.
    func observe(
        step: ConversionSafetyProfileStep, reply: AXWriteReply?, expected: AXProfileExpectedState,
        ledger: ConversionSafetyLedger
    ) -> Bool {
        observeSnapshot(step: step, reply: reply, expected: expected, ledger: ledger) != nil
    }

    /// Snapshot используется только синхронно; это не разрешение на последующий RPC или await.
    func observeSnapshot(
        step: ConversionSafetyProfileStep, reply: AXWriteReply?, expected: AXProfileExpectedState,
        ledger: ConversionSafetyLedger
    ) -> AXProfileSnapshot? {
        guard !Task.isCancelled, operation == ledger.operation, ledger.profileBinding == binding,
              ledger.decision == nil, !ledger.hasProfileFault, reply == nil || reply?.status == .success,
              let ticket = ledger.beginProfileObservation(step: step, submission: reply?.submission, binding: binding)
        else { _ = fault(.snapshotMismatch, ledger: ledger); return nil }
        guard let snapshot = read(expected: expected, ledger: ledger) else { return nil }
        guard ledger.observeUnderProfile(ticket, binding: binding) else {
            _ = fault(.snapshotMismatch, ledger: ledger)
            return nil
        }
        return snapshot
    }

    func read(expected: AXProfileExpectedState?, ledger: ConversionSafetyLedger) -> AXProfileSnapshot? {
        guard isCurrent(ledger: ledger) else { return nil }
        var denied = false
        let snapshot = diagnostics.measure(.snapshot) {
            environment.snapshot(element) {
                guard !denied, self.isCurrent(ledger: ledger) else { denied = true; return false }
                return true
            }
        }
        guard !denied, isCurrent(ledger: ledger) else { return nil }
        guard let snapshot else { _ = fault(.snapshotUnavailable, ledger: ledger); return nil }
        let matches = expected.map {
            snapshot.text.utf16.elementsEqual($0.text.utf16) && $0.selections.contains(snapshot.selection)
        } ?? true
        guard snapshot.isComplete, matches, matchesInitialUndo(snapshot, ledger: ledger) else {
            _ = fault(.snapshotMismatch, ledger: ledger)
            return nil
        }
        return snapshot
    }

    private func matchesInitialUndo(_ snapshot: AXProfileSnapshot, ledger: ConversionSafetyLedger) -> Bool {
        guard let target = requestValidation?.undoTarget, ledger.submissionCount == 0 else { return true }
        guard let span = requestValidation?.undoSpan else { return false }
        return target.matchesInitial(text: snapshot.text, selection: snapshot.selection, span: span)
    }

    @discardableResult
    private func fault(_ reason: ConversionSafetyProfileFault, ledger: ConversionSafetyLedger) -> Bool {
        ledger.recordProfileFault(reason, operation: ledger.operation)
        return false
    }
}
