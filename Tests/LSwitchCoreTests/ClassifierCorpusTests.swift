@testable import LSwitchCore
import XCTest

/// Корпусный тест классификатора (задача 2.2): реальные предложения на
/// обоих языках + код + смешанные тексты. Метрики:
/// - ложные срабатывания (слово набрано правильно, а классификатор хочет
///   конвертировать) ≤ 1%;
/// - покрытие: словарные слова, набранные в неправильной раскладке
///   (симуляция через invert), конвертируются ≥ 97% — меряем на
///   топ-2000 частотных слов каждого словаря.
final class ClassifierCorpusTests: XCTestCase {

    private let classifier = WordClassifier(personalDictionary: PersonalDictionary(defaults: freshSuite()))

    private static func freshSuite() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "lswitch.tests.\(UUID().uuidString)") else {
            fatalError("Не удалось создать тестовый UserDefaults")
        }
        return defaults
    }

    // MARK: - Корпус предложений

    private static let russianSentences = """
    Сегодня утром я пошёл в магазин за хлебом и молоком.
    Мы давно не виделись и нам есть что обсудить.
    Эта книга оказалась гораздо интереснее чем я ожидал.
    Завтра будет дождь поэтому возьми зонт.
    Она работает врачом в городской больнице уже десять лет.
    Дети играли во дворе и громко смеялись.
    Мне нужно закончить отчёт до пятницы.
    В этой деревне каждый дом держит свою историю.
    Он обещал позвонить как только освободится.
    Поезд прибывает на третью платформу через десять минут.
    Мы купили билеты в театр на субботу.
    Не забудь полить цветы перед отъездом.
    Этот фильм получил главный приз фестиваля.
    Река весной выходит из берегов и затопляет луг.
    Бабушка печёт лучшие пирожки на свете.
    Студенты готовились к экзамену всю неделю.
    На завтрак были блины с мёдом и сметаной.
    Он прочитал письмо дважды прежде чем ответить.
    В лесу после дождя появилось много грибов.
    Она быстро собрала чемодан и вызвала такси.
    Наш город сильно изменился за последние годы.
    Учитель объяснил тему ещё раз для тех кто не понял.
    Зимой дни короткие а вечера длинные.
    Кошка спала на подоконнике весь день.
    Мы договорились встретиться у входа в метро.
    Этот вопрос требует серьёзного обсуждения.
    Врач посоветовал больше гулять и меньше волноваться.
    На полке стояли старые фотографии и письма.
    Он всегда приходит на работу раньше всех.
    Погода в горах меняется очень быстро.
    Мы будем рады видеть тебя в гостях в любое время.
    """

    private static let englishSentences = """
    I need to finish this report before the end of the week.
    She has been working at the hospital for ten years.
    We haven't seen each other for a long time.
    This book turned out to be much more interesting than I expected.
    Don't forget to water the plants before you leave.
    The train arrives at the third platform in ten minutes.
    He promised to call as soon as he gets free.
    The children were playing in the yard and laughing loudly.
    We bought tickets to the theatre for Saturday.
    This movie won the main prize at the festival.
    She quickly packed her suitcase and called a taxi.
    The teacher explained the topic once more for those who didn't understand.
    Our city has changed a lot in recent years.
    The cat slept on the windowsill all day long.
    We agreed to meet at the metro entrance.
    This question requires serious discussion.
    The weather in the mountains changes very quickly.
    He always comes to work earlier than everyone else.
    There were old photographs and letters on the shelf.
    The doctor advised him to walk more and worry less.
    After the rain many mushrooms appeared in the forest.
    Grandma bakes the best pies in the world.
    The students were preparing for the exam all week.
    For breakfast there were pancakes with honey and sour cream.
    He read the letter twice before answering.
    In winter the days are short and the evenings are long.
    Tomorrow it will rain so take an umbrella.
    This morning I went to the store for bread and milk.
    The river overflows its banks in spring and floods the meadow.
    Every house in this village keeps its own story.
    """

    private static let codeSnippets = """
    func convert(text string from layout) returns string
    let buffer capacity reserve append remove
    var result success failure error throw catch
    class struct enum protocol extension import return
    private public static final override init self nil true false
    if else guard switch case default while repeat break continue
    """

    // MARK: - Метрики

    private func words(from text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init)
    }

    private func falsePositiveRate(_ sentences: String) -> Double {
        let corpusWords = words(from: sentences).filter { WordClassifier.passesHeuristics($0) }
        let wrong = corpusWords.filter {
            if case .wrongLayout = classifier.verdict(for: $0) { return true }
            return false
        }
        return Double(wrong.count) / Double(corpusWords.count)
    }

    func testFalsePositivesOnRussianCorpus() {
        XCTAssertLessThanOrEqual(falsePositiveRate(Self.russianSentences), 0.01)
    }

    func testFalsePositivesOnEnglishCorpus() {
        XCTAssertLessThanOrEqual(falsePositiveRate(Self.englishSentences), 0.01)
    }

    func testFalsePositivesOnCode() {
        XCTAssertLessThanOrEqual(falsePositiveRate(Self.codeSnippets), 0.01)
    }

    /// Покрытие: частотное слово, набранное в чужой раскладке (симуляция
    /// через invert), должно конвертироваться.
    func testCoverageOnFrequentWords() throws {
        let bundle = Bundle.module
        var checked = 0
        var converted = 0
        for (resource, _) in [("ru.words", Layout.russian), ("en.words", Layout.english)] {
            let url = try XCTUnwrap(bundle.url(forResource: resource, withExtension: "txt"))
            let top2000 = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").prefix(2000).map(String.init)
            for word in top2000 {
                let mistyped = LayoutMap.shared.invert(word)
                guard WordClassifier.passesHeuristics(mistyped) else { continue }
                checked += 1
                if case .wrongLayout(let back) = classifier.verdict(for: mistyped) {
                    XCTAssertEqual(back, word, "mistyped \(mistyped) конвертировано не в \(word)")
                    converted += 1
                }
            }
        }
        let coverage = Double(converted) / Double(checked)
        XCTAssertGreaterThanOrEqual(coverage, 0.97, "покрытие \(coverage) при \(checked) словах")
    }
}
