import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionTransportRetentionTests: XCTestCase {
    func testRetentionCallbackIsOneShotOutsideLockAndCanCompleteAndReenter() async {
        let probe = TransportRetentionProbe()
        let transport = ConversionOrdinaryTransport(onRetentionRequested: { probe.retained() })
        probe.transport = transport
        let returned = expectation(description: "Retention callback вернулся без lock deadlock")
        DispatchQueue.global().async {
            transport.requestRetention()
            transport.requestRetention()
            returned.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [returned], timeout: 2) == .completed else {
            return XCTFail("Callback не должен выполняться под transport lock")
        }
        XCTAssertEqual(probe.calls, 1)
        let result = await transport.waitForTerminal()
        XCTAssertEqual(result, .retainedFailure)
    }
}

private final class TransportRetentionProbe: @unchecked Sendable {
    // Публикуется до DispatchQueue.async; после старта callback ссылка не меняется.
    weak var transport: ConversionOrdinaryTransport?
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func retained() {
        lock.lock()
        count += 1
        lock.unlock()
        XCTAssertEqual(transport?.retentionRequested, true)
        XCTAssertEqual(transport?.complete(.retainedFailure), true)
        transport?.requestRetention()
    }
}
