import ApplicationServices
import Foundation

/// Только профильный batch. Unknown не считается отсутствующим атрибутом защиты.
enum AXProfileProtectionMetadata {
    static let attributes = [kAXSubroleAttribute, "AXProtectedContent"]

    static func isProtected(_ values: [CFTypeRef]?) -> Bool {
        guard let values, values.count == 2,
              let secureRole = subrole(values[0]), let protected = flag(values[1]) else { return true }
        return secureRole || protected
    }

    private static func subrole(_ value: CFTypeRef) -> Bool? {
        if let role = value as? String { return role == "AXSecureTextField" }
        return knownAbsent(value) ? false : nil
    }

    private static func flag(_ value: CFTypeRef) -> Bool? {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return value as? Bool }
        return knownAbsent(value) ? false : nil
    }

    private static func knownAbsent(_ value: CFTypeRef) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        // swiftlint:disable:next force_cast
        let wrapped = value as! AXValue
        var error = AXError.failure
        guard AXValueGetType(wrapped) == .axError, AXValueGetValue(wrapped, .axError, &error) else { return false }
        return error == .noValue || error == .attributeUnsupported
    }
}
