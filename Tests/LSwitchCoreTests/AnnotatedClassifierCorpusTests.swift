import Foundation
@testable import LSwitchCore
import XCTest

private struct CorpusMetrics {
    var total = 0
    var correct = 0
    var negatives = 0
    var falsePositives = 0
    var positives = 0
    var recovered = 0

    var accuracy: Double { Double(correct) / Double(max(total, 1)) }
    var falsePositiveRate: Double { Double(falsePositives) / Double(max(negatives, 1)) }
    var recall: Double { Double(recovered) / Double(max(positives, 1)) }

    mutating func record(input: String, expected: String, actual: String) {
        total += 1
        if actual == expected { correct += 1 }
        if input == expected {
            negatives += 1
            if actual != input { falsePositives += 1 }
        } else {
            positives += 1
            if actual == expected { recovered += 1 }
        }
    }

    var description: String {
        "samples=\(total) correct=\(correct) accuracy=\(String(format: "%.4f", accuracy)) " +
            "FP=\(falsePositives)/\(negatives) rate=\(String(format: "%.4f", falsePositiveRate)) " +
            "recovered=\(recovered)/\(positives) recall=\(String(format: "%.4f", recall))"
    }
}

final class AnnotatedClassifierCorpusTests: XCTestCase {
    private func tokens(_ sentence: String) throws -> [(input: String, expected: String)] {
        // Пары меток сохраняют раскладочную пунктуацию; немаркированные лексические слова — отрицательные примеры.
        let pattern = #"<([^|>]+)\|([^>]+)>|[\p{L}\p{N}_]+(?:['-][\p{L}\p{N}_]+)*"#
        let expression = try NSRegularExpression(pattern: pattern)
        let text = sentence as NSString
        return expression.matches(in: sentence, range: NSRange(location: 0, length: text.length)).map { match in
            if match.range(at: 1).location != NSNotFound {
                return (text.substring(with: match.range(at: 1)), text.substring(with: match.range(at: 2)))
            }
            let unchanged = text.substring(with: match.range)
            return (unchanged, unchanged)
        }
    }

    func testCorpusSizeCompositionAndIndependentLabels() throws {
        let sentences = AnnotatedClassifierCorpus.sentences
        XCTAssertGreaterThanOrEqual(sentences.filter { $0.category != .code }.count, 100)
        XCTAssertEqual(Set(sentences.map(\.identifier)).count, sentences.count)
        for category in AnnotatedClassifierCorpus.Category.allCases {
            XCTAssertFalse(sentences.filter { $0.category == category }.isEmpty)
        }
        let annotated = try sentences.flatMap { try tokens($0.annotated) }
        XCTAssertGreaterThanOrEqual(annotated.filter { $0.input != $0.expected }.count, 80)
        let punctuation = try tokens("<rf;tncz|кажется> and let ghbdtn = user_value")
        XCTAssertEqual(punctuation.first?.input, "rf;tncz")
        XCTAssertEqual(punctuation.first?.expected, "кажется")
        XCTAssertTrue(punctuation.contains { $0.input == "ghbdtn" && $0.expected == "ghbdtn" })
        XCTAssertTrue(punctuation.contains { $0.input == "user_value" && $0.expected == "user_value" })
    }

    func testAccuracyAndFalsePositivesOnFixedAnnotatedCorpus() throws {
        let name = "lswitch.tests.annotated-corpus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let classifier = WordClassifier(personalDictionary: PersonalDictionary(defaults: defaults))
        var overall = CorpusMetrics()
        var categories: [AnnotatedClassifierCorpus.Category: CorpusMetrics] = [:]
        var mistakes: [String] = []
        for sentence in AnnotatedClassifierCorpus.sentences {
            for token in try tokens(sentence.annotated) {
                let actual: String
                if case .wrongLayout(let converted) = classifier.verdict(for: token.input) {
                    actual = converted
                } else {
                    actual = token.input
                }
                overall.record(input: token.input, expected: token.expected, actual: actual)
                categories[sentence.category, default: CorpusMetrics()].record(
                    input: token.input, expected: token.expected, actual: actual
                )
                if actual != token.expected {
                    mistakes.append("\(sentence.identifier): \(token.input) → \(actual), ожидалось \(token.expected)")
                }
            }
        }
        print("corpus.overall sentences=\(AnnotatedClassifierCorpus.sentences.count) \(overall.description)")
        for category in AnnotatedClassifierCorpus.Category.allCases {
            print("corpus.\(category.rawValue) \(categories[category, default: CorpusMetrics()].description)")
        }
        for mistake in mistakes { print("corpus.mismatch \(mistake)") }
        XCTAssertGreaterThanOrEqual(overall.accuracy, 0.97, mistakes.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(overall.falsePositiveRate, 0.01, mistakes.joined(separator: "\n"))
    }
}
