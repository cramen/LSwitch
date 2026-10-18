import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileProtectionTests: XCTestCase {
    func testKnownClearAndProtectedFieldsAreDecodedAtTheirFixedPositions() throws {
        let clear = try XCTUnwrap(kCFBooleanFalse)
        let protected = try XCTUnwrap(kCFBooleanTrue)
        XCTAssertFalse(AXProfileProtectionMetadata.isProtected(["AXUnknown" as CFString, clear]))
        XCTAssertTrue(AXProfileProtectionMetadata.isProtected(["AXSecureTextField" as CFString, clear]))
        XCTAssertTrue(AXProfileProtectionMetadata.isProtected(["AXUnknown" as CFString, protected]))
        XCTAssertEqual(AXProfileProtectionMetadata.attributes, [kAXSubroleAttribute, "AXProtectedContent"])
    }

    func testOnlyExplicitKnownAbsenceMayReplaceMissingProtectionMetadata() throws {
        for error in [AXError.noValue, .attributeUnsupported] {
            var error = error
            let value = try XCTUnwrap(AXValueCreate(.axError, &error))
            XCTAssertFalse(AXProfileProtectionMetadata.isProtected([value, value]))
        }
        for error in [AXError.cannotComplete, .invalidUIElement, .failure, .success] {
            var error = error
            let value = try XCTUnwrap(AXValueCreate(.axError, &error))
            XCTAssertTrue(AXProfileProtectionMetadata.isProtected([value, value]))
        }
    }

    func testUnknownPartialExtraAndWrongTypedBatchesFailClosed() throws {
        let role = "AXUnknown" as CFString
        let clear = try XCTUnwrap(kCFBooleanFalse)
        let null = try XCTUnwrap(kCFNull)
        let invalid: [[CFTypeRef]] = [[], [role], [role, clear, clear], [role, null], [null, clear],
                                     [role, "false" as CFString], [role, NSNumber(value: 0)], [clear, role]]
        XCTAssertTrue(AXProfileProtectionMetadata.isProtected(nil))
        for values in invalid { XCTAssertTrue(AXProfileProtectionMetadata.isProtected(values)) }
    }

    func testOtherAXValueTypesCannotMasqueradeAsAbsence() throws {
        var range = CFRange(location: 0, length: 0)
        let wrapped = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        XCTAssertTrue(AXProfileProtectionMetadata.isProtected([wrapped, wrapped]))
    }
}
