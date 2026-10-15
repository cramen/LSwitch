import Darwin
@testable import LSwitchCore
import XCTest

final class SystemProcessIdentityTests: XCTestCase {
    func testOwnProcessHasStableBirthIdentity() throws {
        let identity = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
        XCTAssertEqual(identity.processID, getpid())
        XCTAssertEqual(SystemProcessIdentity.read(processID: getpid()), identity)
        XCTAssertTrue(SystemProcessIdentity.isCurrent(identity))
    }

    func testMatchingPIDWithAnotherBirthDoesNotConfirmIdentity() throws {
        let identity = try XCTUnwrap(RecoveryProcessIdentity(
            processID: getpid(), birthSeconds: 1, birthMicroseconds: 0
        ))
        XCTAssertFalse(SystemProcessIdentity.isCurrent(identity))
    }

    func testInvalidOrAbsentProcessDoesNotProduceIdentity() {
        for processID: Int32 in [-1, 0, Int32.max] {
            XCTAssertNil(SystemProcessIdentity.read(processID: processID))
        }
    }
}
