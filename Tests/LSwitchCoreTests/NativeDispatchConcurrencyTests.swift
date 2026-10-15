import Foundation
@testable import LSwitchCore
import XCTest

final class NativeDispatchConcurrencyTests: XCTestCase {
    @MainActor
    func testConcurrentDuplicateReleaseCanBeAdmittedOnlyOnce() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let shape = fixture.keyPair
        let target = fixture.target
        let pair = try XCTUnwrap(registry.reservePairs([shape])?.first)
        let down = try fixture.token()
        let release = try fixture.token(.balancingRelease)
        XCTAssertTrue(registry.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        XCTAssertTrue(registry.registerSubmitted(pair.release, token: release, scope: fixture.scope))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: shape.down, target: target), .admitted(down))
        registry.closeGeneration()
        let results = NativeAdmissionResults()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            results.append(registry.observe(marker: pair.release.marker, shape: shape.release, target: target))
        }
        XCTAssertEqual(results.values.filter { $0 == .admitted(release) }.count, 1)
        XCTAssertEqual(results.values.filter { $0 == .rejected(.duplicate) }.count, 31)
        XCTAssertEqual(registry.status(of: pair.release), .admitted(release))
    }

    @MainActor
    func testConcurrentQuarantineAndLossNeverRestoreMutationPermission() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let target = fixture.target
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index.isMultiple(of: 2) { gate.markLost() } else { _ = gate.observeUnmatchedTargetDown(target: target) }
        }
        XCTAssertEqual(gate.snapshot.phase, .lost)
        XCTAssertTrue(gate.snapshot.handoverRequested)
        XCTAssertFalse(gate.snapshot.permitsMutation)
        XCTAssertFalse(gate.activateProtection(scope: fixture.scope))
        XCTAssertFalse(gate.observeUnmatchedTargetDown(target: target).protectionAvailable)
    }
}

private final class NativeAdmissionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NativeDispatchAdmission] = []

    var values: [NativeDispatchAdmission] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ result: NativeDispatchAdmission) {
        lock.lock()
        stored.append(result)
        lock.unlock()
    }
}
