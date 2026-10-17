import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionOrdinaryTransportTests: XCTestCase {
    func testFirstTerminalResultCannotBeReplacedByLaterFailure() async {
        let transport = ConversionOrdinaryTransport()
        XCTAssertTrue(transport.complete(.locallyDispatched))
        XCTAssertFalse(transport.complete(.retainedFailure))
        transport.requestRetention()
        let result = await transport.waitForTerminal()
        XCTAssertEqual(result, .locallyDispatched)
        XCTAssertFalse(transport.retentionRequested)
    }

    func testRetentionRequestDoesNotManufactureTerminalDeliveryOrFailure() async {
        let transport = ConversionOrdinaryTransport()
        transport.requestRetention()
        XCTAssertTrue(transport.retentionRequested)
        XCTAssertTrue(transport.complete(.retainedFailure))
        XCTAssertFalse(transport.complete(.locallyDispatched))
        let result = await transport.waitForTerminal()
        XCTAssertEqual(result, .retainedFailure)
    }

    func testRepeatedWaitIsAProtocolRefusalWithoutSecondCompletion() async {
        let transport = ConversionOrdinaryTransport()
        XCTAssertTrue(transport.complete(.retainedFailure))
        let first = await transport.waitForTerminal()
        let repeated = await transport.waitForTerminal()
        XCTAssertEqual(first, .retainedFailure)
        XCTAssertNil(repeated)
    }
}
