import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXTextEditContextBatchTests: XCTestCase {
    func testFixedBatchOrderDecodesDocumentStringAndTypedErrorsWithoutPayloadReads() throws {
        let window = AXUIElementCreateApplication(100)
        let values: [CFTypeRef] = [kAXTextAreaRole as CFString, window, "file:///fixture/test.txt" as CFString]
        let metadata = try XCTUnwrap(AXTextEditElementMetadata.decode(values))
        XCTAssertEqual(metadata.role, kAXTextAreaRole)
        XCTAssertTrue(CFEqual(metadata.window, window))
        XCTAssertEqual(metadata.document, .value("file:///fixture/test.txt"))
        XCTAssertEqual(AXTextEditElementMetadata.attributes,
                       [kAXRoleAttribute, kAXWindowAttribute, kAXDocumentAttribute])
        for error in [AXError.noValue, .attributeUnsupported, .cannotComplete] {
            var raw = error
            let wrapped = try XCTUnwrap(AXValueCreate(.axError, &raw))
            let decoded = try XCTUnwrap(AXTextEditElementMetadata.decode([values[0], window, wrapped]))
            XCTAssertEqual(decoded.document, error == .noValue ? .missing : .unavailable)
        }
        let null = try XCTUnwrap(kCFNull)
        XCTAssertEqual(AXTextEditElementMetadata.decode([values[0], window, null])?.document, .unavailable)
    }

    func testPartialExtraReorderedAndWrongTypedBatchCannotProduceContext() throws {
        let role = kAXTextAreaRole as CFString
        let window = AXUIElementCreateApplication(100)
        let document = "file:///fixture/test.txt" as CFString
        let null = try XCTUnwrap(kCFNull)
        let invalid: [[CFTypeRef]] = [[], [role, window], [role, window, document, null],
                                     [window, role, document], [null, window, document],
                                     [role, document, document], [role, window, NSNumber(value: 1)],
                                     [role, window, NSNumber(value: true)], [role, window, [:] as CFDictionary]]
        for values in invalid { XCTAssertNil(AXTextEditElementMetadata.decode(values)) }
    }

    func testWrongAXValueTypeCannotMasqueradeAsMissingDocument() throws {
        var range = CFRange(location: 0, length: 0)
        let wrapped = try XCTUnwrap(AXValueCreate(.cfRange, &range))
        XCTAssertNil(AXProfileDocumentValue.batchValue(wrapped))
        XCTAssertNil(AXTextEditElementMetadata.decode([
            kAXTextAreaRole as CFString, AXUIElementCreateApplication(100), wrapped
        ]))
    }
}
