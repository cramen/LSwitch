import Foundation

/// Одно сохранённое inverse-основание из typed receipt. Данные остаются в прежнем RAM undo.
@MainActor
final class ConversionUndoProfileAnchor {
    let target: AXProfileReceiptTarget
    private let original: String
    private let converted: String
    private let trailingText: String
    private let bundleID: String

    init?(receipt: ConversionReceipt, bundleID: String) {
        guard let target = receipt.profileTarget, target.hasFinalSelection else { return nil }
        self.target = target
        original = receipt.original
        converted = receipt.converted
        trailingText = receipt.trailingText
        self.bundleID = bundleID
    }

    var span: String { converted + trailingText }

    func matches(_ record: UndoRecord) -> Bool {
        record.bundleID == bundleID && record.original.utf16.elementsEqual(original.utf16)
            && record.converted.utf16.elementsEqual(converted.utf16)
            && record.trailingText.utf16.elementsEqual(trailingText.utf16)
    }

    func matches(_ input: CanonicalConversionRequestInput) -> Bool {
        input.replacement?.utf16.elementsEqual(original.utf16) == true
            && input.expectedWord?.utf16.elementsEqual(converted.utf16) == true
            && input.trailingText.utf16.elementsEqual(trailingText.utf16)
            && input.sourceLayout == nil && !input.useSelection
    }
}
