#if DEBUG
import ApplicationServices
import Foundation

/// Настоящий selection RPC остаётся у original; fault wrapper не подменяет успех или текст результата.
@MainActor
struct TextEditRecoveryFaultAccess: AXTextAccess {
    let original: any AXTextAccess
    let fixture: TextEditRecoveryFaultFixture
    private let selected: Selection

    @MainActor
    private final class Selection {
        var element: AXUIElement?
        var range: NSRange?
    }

    init(original: any AXTextAccess, fixture: TextEditRecoveryFaultFixture) {
        self.original = original
        self.fixture = fixture
        selected = Selection()
    }

    func focusedElement() -> AXUIElement? { original.focusedElement() }
    func isProtected(_ element: AXUIElement) -> Bool { original.isProtected(element) }
    func text(in element: AXUIElement) -> String? { original.text(in: element) }
    func selection(in element: AXUIElement) -> NSRange? { original.selection(in: element) }
    func canReplaceText(in element: AXUIElement) -> Bool { original.canReplaceText(in: element) }
    func canSetSelection(in element: AXUIElement) -> Bool { original.canSetSelection(in: element) }
    func automaticContext(in element: AXUIElement) -> AutomaticTextContext { original.automaticContext(in: element) }
    func documentIdentity(in element: AXUIElement) -> String? { original.documentIdentity(in: element) }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool { fixture.blockWrite(); return false }
    func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool { fixture.blockWrite(); return false }
    func prepareReplacement(_ text: String, in element: AXUIElement) -> AXPreparedWrite? {
        fixture.blockWrite()
        return nil
    }

    func prepareSelection(_ range: NSRange, in element: AXUIElement) -> AXPreparedWrite? {
        guard let prepared = original.prepareSelection(range, in: element) else { return nil }
        return AXPreparedWrite { token in
            guard let token, fixture.beginSelection() else { return .cannotComplete }
            // Передаётся тот же уже зарегистрированный token; второй willSubmit не вызывается.
            let status = prepared.submit(beforeSend: { token })?.status ?? .cannotComplete
            selected.element = element
            selected.range = range
            fixture.didSelect(status)
            return status
        }
    }

    func waitForUpdate() async {
        await fixture.waitForPrefix {
            guard let element = selected.element, let range = selected.range else { return false }
            return original.selection(in: element) == range
        }
    }
}
#endif
