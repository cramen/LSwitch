@testable import LSwitchCore
import XCTest

#if DEBUG
final class LayoutDecisionDiagnosticsTests: XCTestCase {
    func testAlphabetCategoriesDoNotNeedOrRetainTheOriginalText() {
        XCTAssertEqual(ConversionLayoutMetadata.alphabet("Hello, 123!"), .english)
        XCTAssertEqual(ConversionLayoutMetadata.alphabet("Привет ёЁ!"), .russian)
        XCTAssertEqual(ConversionLayoutMetadata.alphabet("Hello привет"), .mixed)
        XCTAssertEqual(ConversionLayoutMetadata.alphabet("42 / 😀"), .unknown)
        XCTAssertEqual(ConversionLayoutMetadata.alphabet("éλ"), .unknown)
    }

    @MainActor
    func testRussianReceiptChoosesEnglishAndReportsAdapterAndReadback() async throws {
        let fixture = ConverterFixture()
        fixture.layout = .russian
        fixture.axEngine.result = .success(.init(original: "привет", converted: "ghbdtn"))
        var samples: [ConversionDiagnostics.Sample] = []
        let trace = diagnostics { samples.append($0) }
        let result = await fixture.converter.trigger(diagnostics: trace)
        XCTAssertEqual(result, .converted(original: "привет", converted: "ghbdtn"))
        let decision = try XCTUnwrap(samples.first { $0.phase == .layoutDecision }?.layoutMetadata)
        XCTAssertEqual(decision.source, .russian)
        XCTAssertEqual(decision.target, .english)
        XCTAssertEqual(decision.original, .russian)
        XCTAssertEqual(decision.converted, .english)
        let observations = samples.filter { $0.phase == .layoutObserved }.compactMap(\.layoutMetadata)
        XCTAssertEqual(observations.map(\.stage), ["adapter", "readback"])
        XCTAssertEqual(observations.map(\.accepted), [true, true])
        XCTAssertEqual(observations.last?.observed, .english)
        XCTAssertEqual(fixture.layoutReadCount, 2)
        XCTAssertTrue(samples.allSatisfy { !$0.logLine.contains("привет") && !$0.logLine.contains("ghbdtn") })
    }

    @MainActor
    func testEnglishReceiptInRussianLayoutReportsAlreadyTargetWithoutSwitch() async {
        let fixture = ConverterFixture()
        fixture.layout = .russian
        fixture.axEngine.result = .success(.init(original: "ghbdtn", converted: "привет"))
        var samples: [ConversionDiagnostics.Sample] = []
        _ = await fixture.converter.trigger(diagnostics: diagnostics { samples.append($0) })
        let decision = samples.first { $0.phase == .layoutDecision }?.layoutMetadata
        XCTAssertEqual(decision?.target, .russian)
        XCTAssertEqual(decision?.original, .english)
        let observations = samples.filter { $0.phase == .layoutObserved }.compactMap(\.layoutMetadata)
        XCTAssertEqual(observations.map(\.stage), ["alreadyTarget"])
        XCTAssertNil(observations.first?.accepted)
        XCTAssertEqual(observations.first?.observed, .russian)
        XCTAssertTrue(fixture.switchedTo.isEmpty)
        XCTAssertEqual(fixture.layoutReadCount, 2)
    }

    @MainActor
    func testRefusalDoesNotAddReadbackOrChangeExistingSwitchBehavior() async {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.succeed(fixture.axEngine)
        var samples: [ConversionDiagnostics.Sample] = []
        let result = await fixture.converter.trigger(diagnostics: diagnostics { samples.append($0) })
        XCTAssertEqual(result, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        let observations = samples.filter { $0.phase == .layoutObserved }.compactMap(\.layoutMetadata)
        XCTAssertEqual(observations.map(\.stage), ["adapter"])
        XCTAssertEqual(observations.first?.accepted, false)
        XCTAssertNil(observations.first?.observed)
        XCTAssertEqual(fixture.layoutReadCount, 1)
    }

    func testTISMetadataRetainsOnlyAllowlistedBuiltinIdentifiers() {
        let mismatch = TISSourceDiagnostics.summary(
            keyboardSourceID: "com.apple.keylayout.Russian", layoutSourceID: "com.apple.keylayout.ABC"
        )
        XCTAssertTrue(mismatch.contains("keyboardCategory=ru"))
        XCTAssertTrue(mismatch.contains("layoutCategory=en"))
        XCTAssertTrue(mismatch.contains("com.apple.keylayout.Russian"))
        XCTAssertTrue(mismatch.contains("com.apple.keylayout.ABC"))
        let custom = TISSourceDiagnostics.summary(keyboardSourceID: "private.custom.keyboard", layoutSourceID: nil)
        XCTAssertFalse(custom.contains("private.custom.keyboard"))
        XCTAssertTrue(custom.contains("keyboardSource=other"))
        XCTAssertTrue(custom.contains("layoutSource=unavailable"))
    }

    @MainActor
    private func diagnostics(_ emit: @escaping (ConversionDiagnostics.Sample) -> Void) -> ConversionDiagnostics {
        ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: false, now: { 20 }, emit: emit
        )
    }
}
#endif
