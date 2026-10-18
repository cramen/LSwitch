#if DEBUG
import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

/// Считает только внешние calls AXTextConverter. Profile читает ту же модель через свой provider.
@MainActor
final class AXCanonicalManualAccess: AXTextAccess {
    let base: AXSafetyTestAccess
    var documentReads = 0
    var focusReads = 0
    var protectionReads = 0
    var automaticReads = 0
    var beforePreparation: () -> Void = {}

    init(_ base: AXSafetyTestAccess) { self.base = base }
    func focusedElement() -> AXUIElement? { focusReads += 1; return base.focusedElement() }
    func isProtected(_ element: AXUIElement) -> Bool { protectionReads += 1; return base.isProtected(element) }
    func documentIdentity(in element: AXUIElement) -> String? { documentReads += 1; return nil }
    func automaticContext(in element: AXUIElement) -> AutomaticTextContext {
        automaticReads += 1
        return base.automaticContext(in: element)
    }
    func text(in element: AXUIElement) -> String? { base.text(in: element) }
    func selection(in element: AXUIElement) -> NSRange? { base.selection(in: element) }
    func canReplaceText(in element: AXUIElement) -> Bool { base.canReplaceText(in: element) }
    func canSetSelection(in element: AXUIElement) -> Bool { base.canSetSelection(in: element) }
    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        base.replaceSelectedText(text, in: element)
    }
    func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool { base.setSelection(range, in: element) }
    func prepareSelection(_ range: NSRange, in element: AXUIElement) -> AXPreparedWrite? {
        beforePreparation()
        return base.prepareSelection(range, in: element)
    }
    func prepareReplacement(_ text: String, in element: AXUIElement) -> AXPreparedWrite? {
        beforePreparation()
        return base.prepareReplacement(text, in: element)
    }
    func waitForUpdate() async { await base.waitForUpdate() }
}

extension AXCombinedProfileFixture {
    func manualRequest() throws -> ConversionRequest {
        .init(canonical: .init(expectedWord: nil, trailingText: "", replacement: nil,
                               sourceLayout: .english, useSelection: true,
                               diagnostics: try XCTUnwrap(request.diagnostics)), session: session)
    }
}
#endif
