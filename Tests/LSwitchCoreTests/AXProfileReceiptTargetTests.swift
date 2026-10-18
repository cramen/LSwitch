#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileReceiptTargetTests: XCTestCase {
    @MainActor
    func testStoredReceiptDoesNotRetainOldProfileSessionOrAdapter() async throws {
        let observed = try await makeReceiptLifetime()
        XCTAssertNil(observed.profile)
        XCTAssertNil(observed.session)
        XCTAssertNil(observed.adapter)
        XCTAssertEqual(observed.receipt.targetIsCurrent?(), true)
        XCTAssertNotNil(observed.receipt.profileTarget)
    }

    @MainActor
    func testInitialAnchorRequiresExactCaretSpanAndUTF16Boundary() throws {
        let fixture = try AXProfileFixture()
        let target = try XCTUnwrap(fixture.profile()).receiptTarget()
        let caret = NSRange(location: 10, length: 0)
        let anchored = target.anchoring(finalSelection: caret)
        XCTAssertFalse(target.hasFinalSelection)
        XCTAssertTrue(anchored.hasFinalSelection)
        XCTAssertTrue(anchored.matchesInitial(text: "😀 привет ", selection: caret, span: "привет "))
        XCTAssertFalse(anchored.matchesInitial(text: "😀 привёт ", selection: caret, span: "привет "))
        XCTAssertFalse(anchored.matchesInitial(text: "😀 привет ", selection: .init(location: 9, length: 0),
                                             span: "привет "))
        let canonical = target.anchoring(finalSelection: .init(location: 3, length: 0))
        XCTAssertFalse(canonical.matchesInitial(text: "e\u{301} ", selection: .init(location: 3, length: 0),
                                               span: "é "))
        let surrogate = target.anchoring(finalSelection: .init(location: 1, length: 0))
        XCTAssertFalse(surrogate.matchesInitial(text: "😀", selection: .init(location: 1, length: 0), span: "A"))
    }

    @MainActor
    func testMalformedOrEmptyInitialGeometryFailsClosedWithoutOverflow() throws {
        let fixture = try AXProfileFixture()
        let target = try XCTUnwrap(fixture.profile()).receiptTarget()
        let ranges = [NSRange(location: Int.min, length: 0), .init(location: Int.max, length: 0),
                      .init(location: 0, length: Int.max), .init(location: 0, length: -1)]
        for range in ranges {
            let anchored = target.anchoring(finalSelection: range)
            XCTAssertFalse(anchored.hasFinalSelection)
            XCTAssertFalse(anchored.matchesInitial(text: "a", selection: range, span: "a"))
        }
        let zero = target.anchoring(finalSelection: .init(location: 0, length: 0))
        XCTAssertFalse(zero.matchesInitial(text: "", selection: .init(location: 0, length: 0), span: ""))
    }

    @MainActor
    private func makeReceiptLifetime() async throws -> AXReceiptLifetime {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let engine = try XCTUnwrap(fixture.session.boundAXEngine)
        let result = await engine.perform(try fixture.manualRequest())
        guard case .success(let receipt) = result else { throw AXReceiptLifetime.Failure.conversion }
        return AXReceiptLifetime(receipt: receipt, fixture: fixture)
    }
}

@MainActor
private final class AXReceiptLifetime {
    enum Failure: Error { case conversion }
    let receipt: ConversionReceipt
    weak var profile: AXObservationProfile?
    weak var session: ConversionRecoverySession?
    weak var adapter: TextEditRecoveryAdapter?

    init(receipt: ConversionReceipt, fixture: AXCombinedProfileFixture) {
        self.receipt = receipt
        profile = fixture.profile
        session = fixture.session
        adapter = fixture.native.adapter
    }
}
#endif
