import ApplicationServices
import Foundation
@testable import LSwitchCore

/// Модель receiver знает завершённые token отдельно от возвращённого AXError.
@MainActor
final class AXSafetyTestAccess: AXTextAccess {
    let model: FakeAXTextAccess
    var preparationAllowed = true
    var bindingAllowed = true
    var contractValid = true
    var exposesCompletion = true
    var missingAfterSelection = false
    var deferFirstSelection = false
    var firstSelectionStatus = AXError.success
    var textStatus = AXError.success
    var preparations = 0
    var replies: [AXError] = []
    var completed: Set<ConversionSafetySubmissionToken> = []
    var delayed: [(ConversionSafetySubmissionToken, NSRange)] = []
    var beforeWrite: (ConversionSafetySubmissionToken) -> Void = { _ in }
    var afterWrite: () -> Void = {}

    init(_ text: String) { self.model = FakeAXTextAccess(text: text) }

    var contract: AXReceiverContract {
        AXReceiverContract { element, operation in
            guard self.bindingAllowed else { return nil }
            return AXBoundReceiverContract(
                element: element, operation: operation,
                isValid: { self.contractValid },
                completion: { reply, _ in
                    let finished = self.exposesCompletion && self.completed.contains(reply.submission)
                    return finished ? .receiverCompleted : .unresolved
                }
            )
        }
    }

    func converter() -> AXTextConverter { AXTextConverter(access: self, receiverContract: contract) }
    func focusedElement() -> AXUIElement? { model.focusedElement() }
    func isProtected(_ element: AXUIElement) -> Bool { model.isProtected(element) }
    func text(in element: AXUIElement) -> String? {
        missingAfterSelection && !model.selectionWrites.isEmpty ? nil : model.text(in: element)
    }
    func selection(in element: AXUIElement) -> NSRange? {
        missingAfterSelection && !model.selectionWrites.isEmpty ? nil : model.selection(in: element)
    }
    func canReplaceText(in element: AXUIElement) -> Bool { model.canReplaceText(in: element) }
    func canSetSelection(in element: AXUIElement) -> Bool { model.canSetSelection(in: element) }
    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        model.replaceSelectedText(text, in: element)
    }
    func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool { model.setSelection(range, in: element) }
    func waitForUpdate() async { await model.waitForUpdate() }
    func documentIdentity(in element: AXUIElement) -> String? { model.documentIdentity(in: element) }
    func automaticContext(in element: AXUIElement) -> AutomaticTextContext { model.automaticContext(in: element) }

    func prepareSelection(_ range: NSRange, in element: AXUIElement) -> AXPreparedWrite? {
        preparations += 1
        guard preparationAllowed else { return nil }
        return AXPreparedWrite { token in
            guard let token else { return .failure }
            self.beforeWrite(token)
            let first = self.model.selectionWrites.isEmpty
            if first, self.deferFirstSelection {
                self.model.selectionWrites.append(range)
                self.delayed.append((token, range))
            } else {
                _ = self.model.setSelection(range, in: element)
                self.completed.insert(token)
            }
            self.afterWrite()
            let status = first ? self.firstSelectionStatus : .success
            self.replies.append(status)
            return status
        }
    }

    func prepareReplacement(_ text: String, in element: AXUIElement) -> AXPreparedWrite? {
        preparations += 1
        guard preparationAllowed else { return nil }
        return AXPreparedWrite { token in
            guard let token else { return .failure }
            self.beforeWrite(token)
            _ = self.model.replaceSelectedText(text, in: element)
            self.completed.insert(token)
            self.afterWrite()
            self.replies.append(self.textStatus)
            return self.textStatus
        }
    }

    func applyDelayedSelection() {
        for (token, range) in delayed {
            model.currentSelection = range
            completed.insert(token)
        }
        delayed.removeAll()
    }
}
