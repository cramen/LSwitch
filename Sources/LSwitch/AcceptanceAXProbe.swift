import AppKit
import ApplicationServices
import Carbon
import Dispatch
import Foundation
import LSwitchCore

/// Запись допускается только в явно названном тестовом документе с точным marker-содержимым.
@MainActor
enum AcceptanceAXProbe {
    @MainActor
    private struct Context {
        let bundleID: String
        let processID: pid_t
        let document: URL
        let element: AXUIElement

        func isCurrent() -> Bool {
            guard !IsSecureEventInputEnabled(),
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == bundleID, app.processIdentifier == processID,
                  documentMatches(processID: processID, expected: document),
                  let focused = focusedElement(), CFEqual(focused, element) else { return false }
            return !AXTextConverter.isSecureField(element)
        }
    }

    private struct State: Equatable {
        let text: String
        let selection: NSRange
    }

    private struct Plan {
        let original: String
        let changed: String
        let probeRange: NSRange
        let originalSelection: NSRange

        var probeCaret: NSRange { NSRange(location: NSMaxRange(probeRange), length: 0) }

        func ownsSelection(_ state: State) -> Bool {
            state.selection == probeRange || state.selection == probeCaret
        }
    }

    static func run(arguments: [String]) -> [String: Any] {
        guard let bundleID = AcceptanceProbe.value("--target-bundle", arguments: arguments),
              let path = AcceptanceProbe.value("--document", arguments: arguments), path.hasPrefix("/") else {
            return ["ok": false, "error": "Нужны --target-bundle и абсолютный --document"]
        }
        let document = URL(fileURLWithPath: path).standardizedFileURL
        guard let expected = expectedText(document: document, arguments: arguments), isFixture(expected) else {
            return ["ok": false, "error": "Тестовый marker/исходник не подтверждён"]
        }
        if arguments.contains("--write"), !permitsWrite(bundleID: bundleID) {
            return ["ok": false, "status": "unconfirmed", "performedWrite": false,
                    "selectionMutationAttempted": false, "writeProhibited": true,
                    "error": "Отложенная AX/DOM-selection не ограничена: write-проба запрещена для этого профиля"]
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID,
              documentMatches(processID: app.processIdentifier, expected: document),
              let element = focusedElement(), !IsSecureEventInputEnabled(),
              !AXTextConverter.isSecureField(element) else {
            return ["ok": false, "error": "Фокус или AXDocument не соответствует выделенному тестовому документу"]
        }
        let context = Context(
            bundleID: bundleID, processID: app.processIdentifier, document: document, element: element
        )
        guard context.isCurrent(), attribute(kAXValueAttribute, element: element) as? String == expected,
              let selection = selection(element), Range(selection, in: expected) != nil else {
            return ["ok": false, "error": "Текст/диапазон не совпадает с подготовленным fixture"]
        }
        let canSelect = isSettable(kAXSelectedTextRangeAttribute, element: element)
        let canWrite = isSettable(kAXSelectedTextAttribute, element: element)
        guard arguments.contains("--write") else {
            return ["ok": true, "status": "capabilities-only", "documentMatched": true,
                    "canSelect": canSelect, "canWrite": canWrite, "performedWrite": false,
                    "writePolicyAllows": permitsWrite(bundleID: bundleID)]
        }
        guard canSelect, canWrite else {
            return ["ok": false, "documentMatched": true, "canSelect": canSelect, "canWrite": canWrite,
                    "performedWrite": false, "error": "AX-атрибуты не доступны для записи"]
        }
        return writeAndRestore(context: context, original: expected, originalSelection: selection)
    }

    private static func expectedText(document: URL, arguments: [String]) -> String? {
        if let encoded = AcceptanceProbe.value("--expected-base64", arguments: arguments) {
            guard let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return try? String(contentsOf: document, encoding: .utf8)
    }

    private static func isFixture(_ text: String) -> Bool {
        let prefix = "LSWITCH_ACCEPTANCE_"
        guard text.hasPrefix(prefix), let line = text.split(separator: "\n").first else { return false }
        let nonce = String(line.dropFirst(prefix.count))
        return nonce.count == 32 && nonce.allSatisfy { "0123456789abcdef".contains($0) } &&
            text == prefix + nonce + "\nghbdtn\n"
    }

    private static func permitsWrite(bundleID: String) -> Bool {
        // Даже два одинаковых readback не доказывают отсутствие поздней DOM-записи Chromium.
        // Read-only capability остаётся доступной; такие приложения не засчитываются как AX write-pass.
        !bundleID.hasPrefix("com.google.Chrome") && !AppProfiles().prefersClipboard(bundleID: bundleID)
    }

    private static func writeAndRestore(
        context: Context, original: String, originalSelection: NSRange
    ) -> [String: Any] {
        guard let word = original.range(of: "ghbdtn") else { return ["ok": false, "status": "unconfirmed"] }
        let plan = Plan(original: original, changed: original.replacingCharacters(in: word, with: "привет"),
                        probeRange: NSRange(word, in: original), originalSelection: originalSelection)
        let baseline = State(text: original, selection: originalSelection)
        guard settled(context: context, allowedTexts: [original], matches: { $0 == baseline }) != nil else {
            return ["ok": false, "status": "unconfirmed", "selectionMutationAttempted": false]
        }
        // Ровно один setter; ожидание никогда не перевыделяет диапазон повторно.
        let selected = setSelection(plan.probeRange, element: context.element)
        let selectedState = settled(context: context, allowedTexts: [original]) {
            $0 == State(text: original, selection: plan.probeRange)
        }
        guard selected, let selectedState, readState(context) == selectedState else {
            let restored = selectedState != nil && restoreRange(plan, context: context)
            return result(phase: "selection", written: false, restored: restored)
        }
        let status = setSelectedText("привет", element: context.element)
        let changedState = settled(context: context, allowedTexts: [original, plan.changed]) {
            $0.text == plan.changed && plan.ownsSelection($0)
        }
        guard let changedState, readState(context) == changedState else {
            // Нельзя двигать selection перед ещё не подтверждённой отложенной текстовой записью.
            return result(phase: "write", written: true, restored: false, axResult: status.rawValue)
        }
        let restored = restoreOriginal(plan, context: context)
        let passed = status == .success && restored
        return ["ok": passed, "status": passed ? "verified-round-trip" : "unconfirmed",
                "performedWrite": true, "selectionMutationAttempted": true, "axResult": status.rawValue,
                "afterMatchesExpected": true, "originalRestored": restored]
    }

    private static func restoreOriginal(_ plan: Plan, context: Context) -> Bool {
        guard let before = readState(context), before.text == plan.changed, plan.ownsSelection(before) else {
            return false
        }
        let selected = setSelection(plan.probeRange, element: context.element)
        let selectedState = settled(context: context, allowedTexts: [plan.changed]) {
            $0 == State(text: plan.changed, selection: plan.probeRange)
        }
        guard selected, let selectedState, readState(context) == selectedState else { return false }
        let status = setSelectedText("ghbdtn", element: context.element)
        let originalState = settled(context: context, allowedTexts: [plan.changed, plan.original]) {
            $0.text == plan.original && plan.ownsSelection($0)
        }
        guard status == .success, let originalState, readState(context) == originalState else { return false }
        return restoreRange(plan, context: context)
    }

    private static func restoreRange(_ plan: Plan, context: Context) -> Bool {
        guard let before = readState(context), before.text == plan.original,
              plan.ownsSelection(before) || before.selection == plan.originalSelection else { return false }
        let selected = setSelection(plan.originalSelection, element: context.element)
        let final = State(text: plan.original, selection: plan.originalSelection)
        let restored = settled(context: context, allowedTexts: [plan.original], matches: { $0 == final })
        return selected && restored == final && readState(context) == final
    }

    /// До четырёх чтений; подтверждение — два одинаковых снимка с паузой не менее 20 мс.
    /// Неизвестный текст/контекст запрещает дальнейшие writes, включая cleanup.
    private static func settled(
        context: Context, allowedTexts: Set<String>, matches: (State) -> Bool
    ) -> State? {
        var previous: State?
        for attempt in 0..<4 {
            guard let current = readState(context), allowedTexts.contains(current.text) else { return nil }
            if matches(current) {
                if current == previous { return current }
                previous = current
            } else {
                previous = nil
            }
            if attempt < 3 { settlePause() }
        }
        return nil
    }

    private static func settlePause() {
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        // Собственный timer не даёт пустому run loop сразу завершиться вместо реальной паузы.
        let timer = Timer(fire: Date().addingTimeInterval(0.02), interval: 0, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
    }

    private static func readState(_ context: Context) -> State? {
        guard context.isCurrent(), let text = attribute(kAXValueAttribute, element: context.element) as? String,
              let range = selection(context.element), Range(range, in: text) != nil,
              context.isCurrent() else { return nil }
        return State(text: text, selection: range)
    }

    private static func result(
        phase: String, written: Bool, restored: Bool, axResult: Int32? = nil
    ) -> [String: Any] {
        var report: [String: Any] = [
            "ok": false, "status": "unconfirmed", "phase": phase, "performedWrite": written,
            "selectionMutationAttempted": true, "originalRestored": restored
        ]
        if let axResult { report["axResult"] = axResult }
        return report
    }

    private static func documentMatches(processID: pid_t, expected: URL) -> Bool {
        let application = AXUIElementCreateApplication(processID)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, element: application),
              let value = attribute(kAXDocumentAttribute, element: window) else { return false }
        if let url = value as? URL { return url.standardizedFileURL == expected }
        guard let string = value as? String, let url = URL(string: string), url.isFileURL else { return false }
        return url.standardizedFileURL == expected
    }

    private static func focusedElement() -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, element: AXUIElementCreateSystemWide())
    }

    private static func elementAttribute(_ name: String, element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, element: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func attribute(_ name: String, element: AXUIElement) -> CFTypeRef? {
        guard AcceptanceProbe.limitMessaging(element) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func selection(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, element: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setSelection(_ range: NSRange, element: AXUIElement) -> Bool {
        guard AcceptanceProbe.limitMessaging(element) == .success else { return false }
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func isSettable(_ name: String, element: AXUIElement) -> Bool {
        guard AcceptanceProbe.limitMessaging(element) == .success else { return false }
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private static func setSelectedText(_ text: String, element: AXUIElement) -> AXError {
        let timeoutStatus = AcceptanceProbe.limitMessaging(element)
        guard timeoutStatus == .success else { return timeoutStatus }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    }
}
