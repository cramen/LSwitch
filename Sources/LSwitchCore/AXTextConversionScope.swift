import ApplicationServices
import Foundation

/// Canonical manual/typed undo profile уже связывает полный документ. Остальные guards остаются отдельными.
@MainActor
struct AXTextConversionScope {
    let request: ConversionRequest
    let context: AutomaticTextContext
    private let targetCheck: ConversionReceipt.TargetCheck?
    private let profileTarget: AXProfileReceiptTarget?

    init?(request: ConversionRequest, element: AXUIElement, access: any AXTextAccess, mutation: AXMutationSafety) {
        if mutation.hasCanonicalProfileBoundary {
            guard let target = mutation.profileReceiptTarget else { return nil }
            self.request = request
            context = .prose
            targetCheck = nil
            profileTarget = target
            return
        }
        let context = request.isAutomatic ? access.automaticContext(in: element) : .prose
        self.context = context
        let identity = request.isAutomatic ? context.documentIdentity : access.documentIdentity(in: element)
        let check = ConversionDocumentTarget.check(identity: identity, read: { access.documentIdentity(in: element) })
        let scoped = request.checkingDocumentContext(context, read: { access.automaticContext(in: element) })
        self.request = request.isAutomatic ? scoped : scoped.checkingTarget(check)
        targetCheck = check
        profileTarget = nil
    }

    func wrap(_ receipt: ConversionReceipt, finalSelection: NSRange) -> ConversionReceipt {
        if let profileTarget {
            return receipt.checkingProfileTarget(profileTarget.anchoring(finalSelection: finalSelection))
        }
        return receipt.checkingTarget(targetCheck)
    }
}
