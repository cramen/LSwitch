/// Независимая фиксированная разметка: <ввод|ожидание> обозначает ошибку раскладки.
/// Все остальные лексические слова размечены «сохранить». Набор не фильтруется по словарям
/// или ответам классификатора; правильные идентификаторы ghbdtn/rfr намеренно оставлены в коде.
/// Корпус оценивает решение WordClassifier, а не системную доставку клавиш или границы UI-поля.
enum AnnotatedClassifierCorpus {
    enum Category: String, CaseIterable {
        case russian
        case english
        case mixed
        case code
    }

    struct Sentence {
        let identifier: String
        let category: Category
        let annotated: String
    }

    static var sentences: [Sentence] {
        var result: [Sentence] = []
        result += entries(russianSentences, category: .russian, prefix: "russianSentences")
        result += entries(englishSentences, category: .english, prefix: "englishSentences")
        result += entries(russianMistakes, category: .russian, prefix: "russianMistakes")
        result += entries(englishMistakes, category: .english, prefix: "englishMistakes")
        result += entries(mixedSentences, category: .mixed, prefix: "mixedSentences")
        result += entries(codeSentences, category: .code, prefix: "codeSentences")
        return result
    }

    private static func entries(_ text: String, category: Category, prefix: String) -> [Sentence] {
        text.split(separator: "\n").enumerated().map { index, line in
            Sentence(identifier: "\(prefix)-\(index + 1)", category: category, annotated: String(line))
        }
    }

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

    private static let russianMistakes = """
    Сегодня <enhjv|утром> мы вместе <regbkb|купили> свежий хлеб.
    Пожалуйста <jnghfdm|отправь> готовый <jnx`n|отчёт> до обеда.
    Завтра наша <rjvfylf|команда> обсудит новый <ghjtrn|проект> дома.
    На столе лежит <rybuf|книга> про дальние <cnhfys|страны> мира.
    Вечером <lhepmz|друзья> придут смотреть <abkmv|фильм> вместе.
    После дождя <djple[|воздух> стал заметно <xbot|чище> вокруг.
    Мы можем <dcnhtnbnmcz|встретиться> возле старого <ntfnhf|театра> завтра.
    Врач попросил <,jkmit|больше> гулять и <hfymit|раньше> ложиться.
    На кухне <gf[ytn|пахнет> кофе и свежими <,ekjxrfvb|булочками> снова.
    Мне нужно <ghjdthbnm|проверить> адрес и <dhtvz|время> встречи.
    Наш <gjtpl|поезд> прибывает на третью <gkfnajhve|платформу> утром.
    Она открыла <jryj|окно> и услышала <gnbw|птиц> снаружи.
    Летом <ltnb|дети> много играют на <ekbwt|улице> вместе.
    Этот вопрос <nht,etn|требует> спокойного <j,ce;ltybz|обсуждения> сегодня.
    В библиотеке можно <yfqnb|найти> нужную <byajhvfwb.|информацию> быстро.
    Он забыл <rk.xb|ключи> и попросил <gjvjob|помощи> у соседей.
    Новая <dthcbz|версия> программы работает <,scnhtt|быстрее> прежней.
    Мы должны <cj[hfybnm|сохранить> копию перед <bpvtytybtv|изменением> файла.
    Пожалуйста <pfgbib|запиши> номер и <gjpdjyb|позвони> после встречи.
    Сегодня <rf;tncz|кажется> будет очень <[jhjifz|хорошая> погода.
    """

    private static let englishMistakes = """
    Please <ыутв|send> the final <кузщке|report> before lunch.
    The <сршдвкут|children> are playing in the <пфквут|garden> today.
    We should <срусл|check> the delivery <фввкуыы|address> again.
    She put the <дуееук|letter> beside the <цштвщц|window> carefully.
    Our <ьууештп|meeting> starts after the <ьщктштп|morning> train arrives.
    Please <куьуьиук|remember> to save your <срфтпуы|changes> before leaving.
    This <зшсегку|picture> reminds me of our <рщдшвфн|holiday> together.
    The <цуферук|weather> is getting much <сщдвук|colder> this evening.
    He wants to <дуфкт|learn> another <дфтпгфпу|language> this year.
    We can <аштшыр|finish> the remaining <цщкл|work> tomorrow.
    The <вщсещк|doctor> asked about my <афьшдн|family> history.
    Please <икштп|bring> a bottle of <цфеук|water> for everyone.
    Her <фтыцук|answer> explains the <зкщидуь|problem> very clearly.
    The <вкшмук|driver> stopped near the <ыефешщт|station> entrance.
    My <акшутв|friend> bought a new <сщьзгеук|computer> yesterday.
    The <дшикфкн|library> closes at seven this <умутштп|evening> today.
    They <щзутув|opened> the gate and <цфдлув|walked> inside quietly.
    We <туув|need> a better <куфыщт|reason> for this decision.
    This <мукышщт|version> supports automatic <гзвфеуы|updates> by default.
    Please <цкшеу|write> your full <тфьу|name> on the form.
    """

    private static let mixedSentences = """
    Сегодня <rjvfylf|команда> проверяет release notes перед встречей.
    Please <срусл|check> новый отчёт перед отправкой заказчику.
    В письме написано <ghbdtn|привет> and welcome to the project.
    The <кузщке|report> содержит выводы о работе сервиса.
    Мы обсуждаем <ghjtrn|проект> together with the design team.
    Нажмите <ryjgre|кнопку> save после изменения документа.
    Please <ыутв|send> файл коллегам после проверки подписи.
    Этот <cthdth|сервер> handles requests without extra delay.
    The new <мукышщт|version> исправляет ошибки обработки текста.
    В окне <yfcnhjtr|настроек> есть отдельный switch для звука.
    Мы читаем API documentation и обсуждаем новые возможности.
    Сегодня release manager проверяет итоговый список изменений.
    Use secure storage для сохранения важных данных приложения.
    Команда выбрала Swift and Python для нового проекта.
    В задаче указаны HTTP status codes и ожидаемые ответы.
    Проверь README перед запуском make test в терминале.
    Встреча начнётся after lunch в большой комнате.
    Этот workflow описывает сборку проекта на macOS.
    Запрос вернул JSON response с подробным описанием ошибки.
    Пользователь написал HELLO и затем русское слово привет.
    """

    private static let codeSentences = """
    let result = formatter.convert(input)
    var retryCount = 3
    if isEnabled { startProcessing() }
    func loadDocument(from path: String) -> Data
    let user_name = request.user_name
    return Result.success(value)
    for item in collection { append(item) }
    guard let context = captureContext() else { return }
    settings.autoSwitchEnabled = false
    let HTTPStatus = response.statusCode
    const total = values.reduce(add, 0)
    console.log("loading complete")
    SELECT name FROM customers WHERE enabled = true
    UPDATE users SET active = false
    path = "/tmp/example.json"
    assert(result == expected)
    let qwertz = unknownIdentifier
    var ghbdtn = currentValue
    let rfr = referenceIdentifier
    let пароль123 = protectedValue
    """
}
