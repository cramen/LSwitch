import CoreGraphics
@testable import LSwitchCore
import XCTest

final class KeyboardEmitterTests: XCTestCase {
    func testCharacterSelectionPressesShiftOnceAndReleasesAfterAllArrows() throws {
        let events = try XCTUnwrap(KeyboardEmitter.events(for: .selectCharacters(3)))
        XCTAssertEqual(events.map(\.type), [
            .flagsChanged, .keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp, .flagsChanged
        ])
        let codes = events.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        XCTAssertEqual(codes, [56, 123, 123, 123, 123, 123, 123, 56])
        XCTAssertTrue(events.dropLast().allSatisfy { $0.flags == .maskShift })
        XCTAssertEqual(events.last?.flags, [])
        XCTAssertTrue(events.allSatisfy { SyntheticEventMarker.isSynthetic($0) })
    }

    func testWholeWordSelectionBalancesShiftAndOptionInReverseOrder() throws {
        let events = try XCTUnwrap(KeyboardEmitter.events(for: .selectWord))
        XCTAssertEqual(events.map(\.type), [
            .flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged
        ])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [56, 58, 123, 123, 58, 56])
        XCTAssertEqual(events.map(\.flags), [
            .maskShift, [.maskShift, .maskAlternate], [.maskShift, .maskAlternate],
            [.maskShift, .maskAlternate], .maskShift, []
        ])
        XCTAssertTrue(events.allSatisfy { SyntheticEventMarker.isSynthetic($0) })
    }

    func testCollapseDoesNotIntroduceModifierTransitions() throws {
        let events = try XCTUnwrap(KeyboardEmitter.events(for: .collapseSelection))
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [124, 124])
        XCTAssertTrue(events.allSatisfy { $0.flags.isEmpty && SyntheticEventMarker.isSynthetic($0) })
    }

    func testInvalidSelectionCountProducesNoPartialModifierSequence() {
        XCTAssertNil(KeyboardEmitter.events(for: .selectCharacters(0)))
        XCTAssertNil(KeyboardEmitter.events(for: .selectCharacters(-1)))
    }
    @MainActor
    func testSelectionChangeAfterCommandDownPreventsVDownAndReleasesCommand() async {
        var posted: [CGEvent] = []
        var selectionMatches = true
        var checks = 0
        let result = await KeyboardEmitter.send(.paste, targetPID: 100, isValid: { true }, beforeKeyDown: {
            checks += 1
            return selectionMatches
        }, delivery: .init(post: { event, targetPID in
            XCTAssertEqual(targetPID, 100)
            posted.append(event)
        }, pause: {
            selectionMatches = false
        }))
        XCTAssertFalse(result)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(posted.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertEqual(posted.map(\.flags), [.maskCommand, []])
        XCTAssertTrue(posted.allSatisfy { SyntheticEventMarker.isSynthetic($0) })
    }

    @MainActor
    func testRangeGuardIsNotRepeatedAfterPasteHasChangedSelection() async {
        var posted: [CGEvent] = []
        var selectionMatches = true
        var checks = 0
        let result = await KeyboardEmitter.send(.paste, targetPID: 100, isValid: { true }, beforeKeyDown: {
            checks += 1
            return selectionMatches
        }, delivery: .init(post: { event, _ in
            posted.append(event)
            if event.type == .keyDown { selectionMatches = false }
        }, pause: {}))
        XCTAssertTrue(result)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(posted.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(posted.last?.flags, [])
    }

    @MainActor
    func testDiagnosticObserverReportsActualCommandBoundariesWithoutChangingPacing() async {
        var phases: [KeyboardEmitter.Phase] = []
        var posted: [CGEventType] = []
        var pauses = 0
        let result = await KeyboardEmitter.send(
            .paste, targetPID: 100, isValid: { true }, beforeKeyDown: { true }, observer: { phases.append($0) },
            delivery: .init(post: { event, _ in posted.append(event.type) }, pause: { pauses += 1 })
        )
        XCTAssertTrue(result)
        XCTAssertEqual(phases, [.started, .commandDown, .keyDown, .returned])
        XCTAssertEqual(posted, [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(pauses, 4)
    }

}
