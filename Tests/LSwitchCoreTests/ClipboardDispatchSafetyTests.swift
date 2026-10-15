import ApplicationServices
import CoreGraphics
@testable import LSwitchCore
import XCTest

final class ClipboardDispatchSafetyTests: XCTestCase {
    @MainActor
    func testKeyboardTokensPrecedeEveryPostWithoutInventingCompletion() async {
        let ledger = ConversionSafetyLedger(generation: 1)
        var kinds: [ConversionSafetySubmissionKind] = []
        var returned: [ClipboardDispatchReply] = []
        var posts = 0
        let hooks = hooks(ledger, onSubmit: { kinds.append($0) }, onReturn: { returned.append($0) })
        let result = await KeyboardEmitter.send(
            .paste, targetPID: 123, isValid: { true }, beforeKeyDown: { true }, hooks: hooks,
            delivery: .init(post: { _, target in
                XCTAssertEqual(target, 123)
                posts += 1
                XCTAssertEqual(ledger.submissionCount, posts)
                XCTAssertEqual(returned.count, posts - 1)
            }, pause: {})
        )
        XCTAssertTrue(result)
        XCTAssertEqual(kinds, [.modifier, .text, .balancingRelease, .balancingRelease])
        XCTAssertEqual(returned.count, 4)
        XCTAssertTrue(ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(ledger.encounteredUnknown, "Возврат post не обрывает ещё выполняющийся chord")
    }

    @MainActor
    func testUnknownAfterCommandDownAllowsOnlyOriginalRecipientRelease() async {
        let ledger = ConversionSafetyLedger(generation: 2)
        var kinds: [ConversionSafetySubmissionKind] = []
        var returned: [ClipboardDispatchReply] = []
        var flags: [CGEventFlags] = []
        let hooks = hooks(ledger, onSubmit: { kinds.append($0) }, onReturn: { returned.append($0) })
        let result = await KeyboardEmitter.send(
            .paste, targetPID: 124, isValid: { true }, beforeKeyDown: { true }, hooks: hooks,
            delivery: .init(post: { event, target in
                XCTAssertEqual(target, 124)
                flags.append(event.flags)
            }, pause: {
                if let first = returned.first { ledger.observe(.unknown, for: first.submission) }
            })
        )
        XCTAssertFalse(result)
        XCTAssertEqual(kinds, [.modifier, .text, .balancingRelease])
        XCTAssertEqual(ledger.submissionCount, 2, "Отвергнутый VDown не становится отправкой")
        XCTAssertEqual(flags, [.maskCommand, []])
    }

    @MainActor
    func testFocusLossAfterVDownBalancesKeyAndModifierWithoutNewDown() async {
        let ledger = ConversionSafetyLedger(generation: 3)
        var valid = true
        var events: [CGEventType] = []
        let hooks = hooks(ledger)
        let result = await KeyboardEmitter.send(
            .paste, targetPID: 125, isValid: { valid }, beforeKeyDown: { true }, hooks: hooks,
            delivery: .init(post: { event, target in
                XCTAssertEqual(target, 125)
                events.append(event.type)
                if event.type == .keyDown { valid = false }
            }, pause: {})
        )
        XCTAssertFalse(result)
        XCTAssertEqual(events, [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(ledger.submissionCount, 4)
    }

    @MainActor
    func testDeniedFirstTokenPostsNothing() async {
        let hooks = ClipboardDispatchHooks(beforeSend: { _ in nil }, didReturn: { _ in XCTFail("Нет отправки") })
        let result = await KeyboardEmitter.send(
            .selectCharacters(2), targetPID: 126, isValid: { true }, beforeKeyDown: { true }, hooks: hooks,
            delivery: .init(post: { _, _ in XCTFail("Не должно быть post") }, pause: {})
        )
        XCTAssertFalse(result)
    }

    @MainActor
    func testMenuErrorRetainsActualSubmissionAndRawReply() {
        let ledger = ConversionSafetyLedger(generation: 4)
        var replies: [ClipboardDispatchReply] = []
        let hooks = hooks(ledger, onReturn: { replies.append($0) })
        var applied = false
        let status = MenuCommand.dispatch(.paste, isValid: { true }, hooks: hooks, perform: {
            XCTAssertEqual(ledger.submissionCount, 1)
            XCTAssertTrue(replies.isEmpty)
            applied = true
            return .cannotComplete
        })
        XCTAssertTrue(applied)
        XCTAssertEqual(status, .cannotComplete)
        XCTAssertEqual(replies.first?.status, .cannotComplete)
        XCTAssertTrue(ledger.hasUnresolvedSubmissions)
    }

    @MainActor
    func testMenuDeniedBeforeSubmissionDoesNotCallAction() {
        let hooks = ClipboardDispatchHooks(beforeSend: { _ in nil }, didReturn: { _ in XCTFail("Нет отправки") })
        let result = MenuCommand.dispatch(.copy, isValid: { true }, hooks: hooks, perform: {
            XCTFail("AXPress не должен вызываться")
            return .success
        })
        XCTAssertNil(result)
    }

    @MainActor
    func testCompletedModifierWithDeniedReleaseCannotUseNoOwnedMutationForReplay() async throws {
        let ledger = ConversionSafetyLedger(generation: 5)
        var posted: [CGEventType] = []
        let hooks = ClipboardDispatchHooks(beforeSend: { kind in
            kind == .modifier ? ledger.willSubmit(kind, operation: ledger.operation) : nil
        }, didReturn: { ledger.observe(.receiverCompleted, for: $0.submission) }, didLeaveDebt: {
            XCTAssertTrue(ledger.recordOutstandingKeyDebt(for: $0))
        })
        let sent = await KeyboardEmitter.send(
            .paste, targetPID: 127, isValid: { true }, beforeKeyDown: { true }, hooks: hooks,
            delivery: .init(post: { event, target in
                XCTAssertEqual(target, 127)
                posted.append(event.type)
            }, pause: {})
        )
        XCTAssertFalse(sent)
        XCTAssertEqual(posted, [.flagsChanged])
        XCTAssertEqual(ledger.submissionCount, 1)
        XCTAssertFalse(ledger.hasEditorMutation)
        XCTAssertFalse(ledger.hasUnresolvedSubmissions)
        XCTAssertTrue(ledger.hasOutstandingKeyDebt)
        let final = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertEqual(final.cleanup, .noOwnedMutation)
        XCTAssertEqual(final.input, .recoveryRequired)
    }

    @MainActor
    private func hooks(
        _ ledger: ConversionSafetyLedger,
        onSubmit: @escaping (ConversionSafetySubmissionKind) -> Void = { _ in },
        onReturn: @escaping (ClipboardDispatchReply) -> Void = { _ in }
    ) -> ClipboardDispatchHooks {
        .init(beforeSend: { kind in
            onSubmit(kind)
            return kind.isCleanup
                ? ledger.willSubmitCleanup(kind, operation: ledger.operation)
                : ledger.willSubmit(kind, operation: ledger.operation)
        }, didReturn: { reply in
            onReturn(reply)
            ledger.observe(.adapterReturned(reply.returnedSuccessfully), for: reply.submission)
        }, submissionCount: { ledger.submissionCount })
    }
}
