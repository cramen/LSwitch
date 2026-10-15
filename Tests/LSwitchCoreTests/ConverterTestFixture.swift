import Foundation
@testable import LSwitchCore

@MainActor
final class StubEngine: ConversionEngine {
    var result: ConversionResult = .unavailable
    var requests: [ConversionRequest] = []
    var handler: ((ConversionRequest) async -> ConversionResult)?

    func perform(_ request: ConversionRequest) async -> ConversionResult {
        requests.append(request)
        if let handler { return await handler(request) }
        return result
    }
}

@MainActor
final class ConverterFixture {
    struct Transition {
        let source: Layout
        let target: Layout
        let startedAt: UInt64
    }

    let axEngine = StubEngine()
    let clipboardEngine = StubEngine()
    let undoStore = UndoStore()
    let rules: AppRules
    var layout: Layout? = .english
    var layoutReadCount = 0
    var switchedTo: [Layout] = []
    var switchSucceeds = true
    var appliesRequestedLayout = true
    var switchHandler: ((Layout) -> Bool)?
    var convertedNotifications = 0
    var transitions: [Transition] = []
    var holdAllowed = true
    var holdActive = false
    var drainHandler: () async -> Void = {}
    var actions: [String] = []
    var bundleID: String? = "com.example.TextEdit"
    var safe = true
    var contextValid = true
    var clipboardPreferred = false

    init() {
        let name = "lswitch.tests.\(UUID().uuidString)"
        rules = AppRules(defaults: UserDefaults(suiteName: name) ?? .standard)
    }

    lazy var converter = Converter(
        currentLayout: { [weak self] in
            self?.layoutReadCount += 1
            return self?.layout
        },
        switchLayout: { [weak self] target in
            guard let self else { return false }
            self.actions.append("layout")
            self.switchedTo.append(target)
            if let switchHandler = self.switchHandler { return switchHandler(target) }
            if self.switchSucceeds && self.appliesRequestedLayout { self.layout = target }
            return self.switchSucceeds
        },
        appRules: rules, undoStore: undoStore,
        frontmostBundleID: { [weak self] in self?.bundleID },
        prefersClipboard: { [weak self] _ in self?.clipboardPreferred == true },
        makeAXEngine: { [axEngine] in axEngine },
        makeClipboardEngine: { [clipboardEngine] in clipboardEngine },
        captureContext: { [weak self] in
            guard let self, self.safe else { return nil }
            return { [weak self] in self?.contextValid == true }
        },
        beginInputHold: { [weak self] in
            guard let self else { return false }
            self.actions.append("hold")
            self.holdActive = self.holdAllowed
            return self.holdAllowed
        },
        endInputHold: { [weak self] in
            self?.actions.append("release")
            self?.holdActive = false
        },
        isInputHoldValid: { [weak self] in self?.holdActive == true },
        drainPendingInput: { [weak self] in await self?.drainHandler() },
        onLayoutSwitched: { [weak self] source, target, startedAt in
            self?.actions.append("record")
            self?.transitions.append(Transition(source: source, target: target, startedAt: startedAt))
        },
        onConverted: { [weak self] in
            self?.actions.append("sound")
            self?.convertedNotifications += 1
        }
    )

    func succeed(_ engine: StubEngine, original: String = "ghbdtn", converted: String = "привет") {
        engine.result = .success(ConversionReceipt(original: original, converted: converted))
    }
}
