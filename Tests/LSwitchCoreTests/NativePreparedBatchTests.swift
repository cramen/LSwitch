import CoreGraphics
import Darwin
@testable import LSwitchCore
import XCTest

final class NativePreparedBatchTests: XCTestCase {
    @MainActor
    func testNativeCommandsKeepOrderPayloadAndPairsWithoutSubmission() throws {
        for command: ClipboardCommand in [.copy, .paste, .selectWord, .selectCharacters(3), .collapseSelection] {
            let gate = try makeGate()
            let events = try XCTUnwrap(KeyboardEmitter.events(for: command))
            let batch = try XCTUnwrap(NativePreparedBatch.prepare(events, gate: gate))
            XCTAssertEqual(batch.packets.count, events.count)
            for (index, packet) in batch.packets.enumerated() {
                let copy = try XCTUnwrap(packet.copyEvent())
                XCTAssertEqual(NativeDispatchShape.readKeyboard(copy), NativeDispatchShape.readKeyboard(events[index]))
                XCTAssertEqual(payload(copy), payload(events[index]))
                XCTAssertEqual(gate.status(of: packet.reservation), .prepared)
                XCTAssertEqual(batch.packets[packet.partnerIndex].partnerIndex, index)
                XCTAssertTrue(NativeDispatchHeader.isOwnReservedEvent(copy))
            }
        }
    }

    @MainActor
    func testUnicodeAndCopiesAreIndependentOfCallerMutation() throws {
        let gate = try makeGate()
        let events = try XCTUnwrap(UnicodeEventEmitter.events(for: "привет"))
        let batch = try XCTUnwrap(NativePreparedBatch.prepare([events.down, events.release], gate: gate))
        events.down.flags = .maskCommand
        events.down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [65])
        let first = try XCTUnwrap(batch.packets.first?.copyEvent())
        XCTAssertEqual(payload(first), Array("привет".utf16))
        XCTAssertTrue(first.flags.isEmpty)
        first.flags = .maskShift
        XCTAssertTrue(try XCTUnwrap(batch.packets.first?.copyEvent()).flags.isEmpty)
    }

    @MainActor
    func testMalformedPairsRefuseWithoutReservingAnything() throws {
        let events = try XCTUnwrap(KeyboardEmitter.events(for: .collapseSelection))
        for malformed in [[events[0]], [events[1]], [events[0], events[0], events[1]],
                          [events[1], events[0]], []] {
            let gate = try makeGate()
            XCTAssertNil(NativePreparedBatch.prepare(malformed, gate: gate))
            XCTAssertEqual(gate.snapshot.entryCount, 0)
        }
        events[1].type = .flagsChanged
        XCTAssertNil(NativePreparedBatch.prepare(events, gate: try makeGate()))
    }

    @MainActor
    func testCapacityAndCommandPreflightAreBounded() throws {
        let gate = try makeGate()
        XCTAssertNil(NativePreparedBatch.prepare(command: .selectCharacters(Int.max), gate: gate))
        XCTAssertNil(NativePreparedBatch.prepare(command: .selectCharacters(0), gate: gate))
        XCTAssertEqual(gate.snapshot.entryCount, 0)
        let batch = try XCTUnwrap(NativePreparedBatch.prepare(command: .selectCharacters(127), gate: gate))
        XCTAssertEqual(batch.packets.count, 256)
        XCTAssertNil(NativePreparedBatch.prepare(command: .copy, gate: gate))
        XCTAssertEqual(gate.snapshot.entryCount, 256)
    }

    @MainActor
    func testClosedGateCannotPrepareNewBatch() throws {
        let gate = try makeGate()
        gate.closeGeneration()
        XCTAssertNil(NativePreparedBatch.prepare(command: .paste, gate: gate))
        XCTAssertEqual(gate.snapshot.entryCount, 0)
    }

    @MainActor
    private func makeGate() throws -> RecipientGateState {
        let ledger = ConversionSafetyLedger(generation: 1)
        let process = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
        return try XCTUnwrap(RecipientGateState(scope: .init(operation: ledger.operation, target: process)))
    }

    private func payload(_ event: CGEvent) -> [UInt16] {
        var count = 0
        var units = [UInt16](repeating: 0, count: 128)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return Array(units.prefix(count))
    }
}
