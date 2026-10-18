import CoreGraphics
import Darwin
@testable import LSwitchCore
import XCTest

final class NativeDispatchBindingTests: XCTestCase {
    @MainActor
    func testUnicodeBoundPacketIsOneShotAndDoesNotUseLegacyTransport() throws {
        let fixture = try Fixture()
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: fixture.gate.scope.target.processID,
                                                              delivery: { _, _ in XCTFail("Legacy post") }))
        let send = try XCTUnwrap(packet.postTracked)
        XCTAssertTrue(send({ true }, fixture.boundHooks))
        XCTAssertFalse(send({ true }, fixture.boundHooks))
        XCTAssertEqual(fixture.posts, 2)
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(fixture.ledger.hasOutstandingKeyDebt)
    }

    @MainActor
    func testUnicodeReleaseLossRetainsDebtAndCannotRepeatDown() throws {
        let fixture = try Fixture()
        fixture.afterPost = { fixture.identityCurrent = false }
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: fixture.gate.scope.target.processID,
                                                              delivery: { _, _ in XCTFail("Legacy post") }))
        let send = try XCTUnwrap(packet.postTracked)
        XCTAssertTrue(send({ true }, fixture.boundHooks))
        XCTAssertTrue(fixture.ledger.hasOutstandingKeyDebt)
        XCTAssertFalse(send({ true }, fixture.boundHooks))
        XCTAssertEqual(fixture.posts, 1)
    }

    @MainActor
    func testEmitterUsesBoundTransportAndLeavesCompletionUnresolved() async throws {
        let fixture = try Fixture()
        let sent = await fixture.sendCopy(pause: {})
        XCTAssertTrue(sent)
        XCTAssertEqual(fixture.posts, 4)
        XCTAssertEqual(fixture.ledger.submissionCount, 4)
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(fixture.ledger.hasOutstandingKeyDebt)
    }

    @MainActor
    func testEmitterFocusLossBalancesOnlyAdmittedModifier() async throws {
        let fixture = try Fixture()
        let sent = await fixture.sendCopy(pause: { fixture.current = false; fixture.gate.closeGeneration() })
        XCTAssertFalse(sent)
        XCTAssertEqual(fixture.posts, 2)
        XCTAssertFalse(fixture.ledger.hasOutstandingKeyDebt)
    }

    @MainActor
    func testEmitterLostProcessRecordsDebtWithoutRetry() async throws {
        let fixture = try Fixture()
        let sent = await fixture.sendCopy(pause: { fixture.identityCurrent = false })
        XCTAssertFalse(sent)
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertTrue(fixture.ledger.hasOutstandingKeyDebt)
    }

    @MainActor
    func testSubmissionPrecedesPostAndAdmissionIsNotCompletion() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.send(0))
        XCTAssertEqual(fixture.posts, 1)
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(fixture.ledger.permitsConfirmedResult)
        XCTAssertFalse(fixture.send(0))
        XCTAssertEqual(fixture.posts, 1)
    }

    @MainActor
    func testAdmittedReleaseCanBalanceAfterCloseAndFocusLoss() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.send(0))
        fixture.gate.closeGeneration()
        fixture.current = false
        XCTAssertTrue(fixture.send(1))
        XCTAssertEqual(fixture.posts, 2)
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
    }

    @MainActor
    func testLostProcessCannotReceiveRelease() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.send(0))
        fixture.identityCurrent = false
        XCTAssertFalse(fixture.send(1))
        XCTAssertEqual(fixture.posts, 1)
    }

    @MainActor
    func testClosureInsideBeforeSendPreventsPostAndKeepsUnknown() throws {
        let fixture = try Fixture()
        fixture.before = { fixture.gate.closeGeneration() }
        XCTAssertFalse(fixture.send(0))
        XCTAssertEqual(fixture.posts, 0)
        XCTAssertTrue(fixture.ledger.hasUnknownSubmissions)
        XCTAssertFalse(fixture.send(0))
        XCTAssertEqual(fixture.ledger.submissionCount, 1)
    }

    @MainActor
    func testForeignTokenAndReleaseBeforeDownNeverPost() throws {
        let fixture = try Fixture()
        XCTAssertFalse(fixture.send(1))
        XCTAssertEqual(fixture.posts, 0)
        let other = ConversionSafetyLedger(generation: 1)
        let hooks = ConversionDispatchHooks(beforeSend: { kind in
            other.willSubmit(kind, operation: other.operation)
        }, didReturn: { _ in XCTFail("Не должно быть post") })
        XCTAssertFalse(fixture.binding.send(fixture.batch.packets[0], kind: .selection,
                                            hooks: hooks, transport: .keyboard))
        XCTAssertEqual(fixture.posts, 0)
    }

    @MainActor
    private final class Fixture {
        let ledger = ConversionSafetyLedger(generation: 1)
        let gate: RecipientGateState
        let batch: NativePreparedBatch
        var posts = 0
        var current = true
        var identityCurrent = true
        var before: () -> Void = {}
        var afterPost: () -> Void = {}
        lazy var binding: NativeDispatchBinding = makeBinding()

        init() throws {
            let process = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
            gate = try XCTUnwrap(RecipientGateState(scope: .init(operation: ledger.operation, target: process)))
            batch = try XCTUnwrap(NativePreparedBatch.prepare(command: .collapseSelection, gate: gate))
            XCTAssertTrue(gate.activateProtection(scope: gate.scope))
        }

        func send(_ index: Int) -> Bool {
            let hooks = ConversionDispatchHooks(beforeSend: { kind in
                let token = kind.isCleanup
                    ? self.ledger.willSubmitCleanup(kind, operation: self.ledger.operation)
                    : self.ledger.willSubmit(kind, operation: self.ledger.operation)
                self.before()
                return token
            }, didReturn: { reply in
                self.ledger.observe(.adapterReturned(true), for: reply.submission)
            })
            return binding.send(batch.packets[index], kind: index == 0 ? .selection : .balancingRelease,
                                hooks: hooks, transport: .keyboard)
        }

        var boundHooks: ConversionDispatchHooks {
            ConversionDispatchHooks(beforeSend: { kind in
                kind.isCleanup
                    ? self.ledger.willSubmitCleanup(kind, operation: self.ledger.operation)
                    : self.ledger.willSubmit(kind, operation: self.ledger.operation)
            }, didReturn: { reply in
                self.ledger.observe(.adapterReturned(true), for: reply.submission)
            }, didLeaveDebt: { self.ledger.recordOutstandingKeyDebt(for: $0) }, nativeBinding: binding)
        }

        func sendCopy(pause: @escaping @MainActor () async -> Void) async -> Bool {
            return await KeyboardEmitter.send(.copy, targetPID: gate.scope.target.processID,
                                              isValid: { self.current }, beforeKeyDown: { true }, hooks: boundHooks,
                                              delivery: .init(post: { _, _ in XCTFail("Legacy post") }, pause: pause))
        }

        private func makeBinding() -> NativeDispatchBinding {
            guard let binding = NativeDispatchBinding(gate: gate, ledger: ledger, isCurrent: { [unowned self] in
                self.current
            }, identityIsCurrent: { [unowned self] _ in self.identityCurrent }, post: { [unowned self] event, target in
                XCTAssertEqual(target, self.gate.scope.target.processID)
                guard let shape = NativeDispatchShape.readKeyboard(event) else { return XCTFail("Нет формы") }
                let result = self.gate.observeOwned(marker: event.getIntegerValueField(.eventSourceUserData),
                                                    shape: shape, target: self.gate.scope.target)
                guard case .admitted(let token) = result.admission else { return XCTFail("Нет submission") }
                XCTAssertTrue(self.ledger.observe(.admitted, for: token))
                self.posts += 1
                self.afterPost()
            }) else { preconditionFailure("Несовместимый fixture") }
            return binding
        }
    }
}
