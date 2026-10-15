import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

extension UnicodeEnvironment {
    static func live() -> UnicodeEnvironment {
        UnicodeEnvironment(
            captureContext: {
                guard let target = InputSafety.captureTarget(),
                      let application = NSRunningApplication(processIdentifier: target.capturedApplicationPID) else {
                    return nil
                }
                let version = application.bundleURL.flatMap { Bundle(url: $0) }?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                let live = UnicodeLiveContext(target: target, application: application, version: version)
                return Context(processID: target.capturedApplicationPID, isCurrent: { live.isCurrent() },
                               rawSnapshot: { live.rawSnapshot(canReadText: $0) },
                               automaticContext: { live.automaticContext() },
                               rawDocumentIdentity: { live.rawDocumentIdentity() })
            }, activeSource: { UnicodeInputSource.current() }, canPost: { CGPreflightPostEventAccess() },
            prepare: { UnicodeEventEmitter.prepare($0, targetPID: $1) },
            sendSelection: { command, processID, before, after in
                let mapped: ClipboardCommand
                switch command {
                case .select(let count): mapped = .selectCharacters(count)
                case .collapse: mapped = .collapseSelection
                }
                // Только общий генератор стрелок; clipboard-среда и Copy/Paste не создаются.
                return KeyboardEmitter.sendBatch(mapped, targetPID: processID, isValid: before, afterBatch: after)
            }, pause: { await SelectionSettlement.pause() }
        )
    }
}

/// Контракт конкретного Chrome provider, не эвристика по любому AXTextArea.
@MainActor
private final class UnicodeLiveContext {
    private let target: InputTarget
    private let bundleID: String?
    private let version: String?
    private let webArea: AXUIElement?
    private let identity = UUID().uuidString
    private var didLogMetadata = false
    #if DEBUG
    private var didLogInvalidSnapshot = false
    #endif
    private static let logger = Logger(subsystem: "LSwitch", category: "UnicodeSnapshot")

    init(target: InputTarget, application: NSRunningApplication, version: String?) {
        self.target = target
        self.bundleID = application.bundleIdentifier
        self.version = version
        self.webArea = Self.webAreaAncestor(of: target.element)
        #if DEBUG
        UnicodePerformance.current?.recordProvider(bundleID: bundleID, version: version, documentRoot: webArea != nil)
        #endif
    }

    func isCurrent() -> Bool {
        #if DEBUG
        return UnicodePerformance.measure(.isCurrent) { target.isCurrent() }
        #else
        return target.isCurrent()
        #endif
    }

    func rawDocumentIdentity() -> String? {
        #if DEBUG
        return UnicodePerformance.measure(.documentIdentity) { readDocumentIdentity() }
        #else
        return readDocumentIdentity()
        #endif
    }

    private func readDocumentIdentity() -> String? {
        if let webArea {
            guard let current = Self.webAreaAncestor(of: target.element), CFEqual(current, webArea) else { return nil }
        }
        // Неизвестный provider получит unverified snapshot, но не прочтёт его текст.
        return identity
    }

    func automaticContext() -> AutomaticTextContext {
        guard isCurrent() else { return .unknown }
        let context = SystemAutomaticTextContext.read(in: target.element)
        return isCurrent() ? context : .unknown
    }

    func rawSnapshot(canReadText: UnicodeEnvironment.TextReadPermission) -> UnicodeTextSnapshot? {
        #if DEBUG
        return UnicodePerformance.measure(.snapshot) { readSnapshot(canReadText: canReadText) }
        #else
        return readSnapshot(canReadText: canReadText)
        #endif
    }

    private func readSnapshot(canReadText: UnicodeEnvironment.TextReadPermission) -> UnicodeTextSnapshot? {
        let role = Self.attribute(kAXRoleAttribute, in: target.element) as? String
        let nearest = Self.elementAttribute("AXEditableAncestor", in: target.element)
        let highest = Self.elementAttribute("AXHighestEditableAncestor", in: target.element)
        let editableRoot = nearest.map { CFEqual($0, target.element) } == true
            && highest.map { CFEqual($0, target.element) } == true
        let provider = UnicodeSnapshotPolicy.permitsProvider(
            bundleID: bundleID, version: version, role: role, editableRoot: editableRoot, documentRoot: webArea != nil
        )
        guard provider else {
            logMetadata(role: role, root: editableRoot, count: false, coordinates: false, bounded: false)
            #if DEBUG
            if !didLogInvalidSnapshot {
                didLogInvalidSnapshot = true
                let flags = "snapshot_invalid providerVerified=false countMatches=notRead"
                    + " coordinatesMatch=notRead selectedTextMatches=notRead provenanceVerified=false"
                    + " editableRoot=\(editableRoot) documentRoot=\(webArea != nil) withinValueBudget=notRead"
                Self.logger.notice("\(flags, privacy: .public)")
            }
            #endif
            return unverifiedSnapshot()
        }
        return readSnapshot(role: role, editableRoot: editableRoot, canReadText: canReadText)
    }

    private func readSnapshot(
        role: String?, editableRoot: Bool, canReadText: UnicodeEnvironment.TextReadPermission
    ) -> UnicodeTextSnapshot? {
        let access = SystemAXTextAccess()
        guard canReadText(), let text = access.text(in: target.element),
              let selection = access.selection(in: target.element), canReadText() else { return nil }
        let count = Self.attribute(kAXNumberOfCharactersAttribute, in: target.element) as? Int
        let bounded = UnicodeSnapshotPolicy.permitsValue(text)
        let coordinates = bounded ? Self.stringForRange(
            NSRange(location: 0, length: text.utf16.count), in: target.element
        ) : nil
        let matchingCoordinates = coordinates.map { text.utf16.elementsEqual($0.utf16) } == true
        let selectionMatches = selectedTextMatches(text: text, selection: selection)
        logMetadata(role: role, root: editableRoot, count: count != nil,
                    coordinates: matchingCoordinates, bounded: bounded)
        let snapshot = UnicodeTextSnapshot(text: text, selection: selection, characterCount: count,
                                           coordinateText: coordinates,
                                           provenance: selectionMatches ? .chromiumTextControl : .unverified)
        #if DEBUG
        if !didLogInvalidSnapshot, !snapshot.isComplete {
            didLogInvalidSnapshot = true
            let countMatches = count == text.utf16.count
            let provenanceVerified = snapshot.provenance == .chromiumTextControl
            let flags = "snapshot_invalid providerVerified=true countMatches=\(countMatches)"
                + " coordinatesMatch=\(matchingCoordinates) selectedTextMatches=\(selectionMatches)"
                + " provenanceVerified=\(provenanceVerified) editableRoot=\(editableRoot)"
                + " documentRoot=\(webArea != nil) withinValueBudget=\(bounded)"
            Self.logger.notice("\(flags, privacy: .public)")
        }
        #endif
        return snapshot
    }

    private func selectedTextMatches(text: String, selection: NSRange) -> Bool {
        guard let range = Range(selection, in: text) else { return false }
        if selection.length == 0 { return true }
        guard let selected = Self.attribute(kAXSelectedTextAttribute, in: target.element) as? String else {
            return false
        }
        return selected.utf16.elementsEqual(text[range].utf16)
    }

    private func unverifiedSnapshot() -> UnicodeTextSnapshot {
        UnicodeTextSnapshot(text: "", selection: NSRange(location: 0, length: 0), characterCount: nil,
                            coordinateText: nil, provenance: .unverified)
    }

    private func logMetadata(role: String?, root: Bool, count: Bool, coordinates: Bool, bounded: Bool) {
        #if DEBUG
        guard !didLogMetadata else { return }
        didLogMetadata = true
        let roleCategory = role == kAXTextAreaRole ? "textArea" : "other"
        let tested = version == UnicodeSnapshotPolicy.testedVersion
        let document = webArea != nil
        Self.logger.notice("role=\(roleCategory, privacy: .public) testedVersion=\(tested, privacy: .public)")
        Self.logger.notice("editableRoot=\(root, privacy: .public) documentRoot=\(document, privacy: .public)")
        Self.logger.notice("countAvailable=\(count, privacy: .public)")
        Self.logger.notice("coordinatesMatch=\(coordinates, privacy: .public)")
        Self.logger.notice("withinValueBudget=\(bounded, privacy: .public)")
        #endif
    }

    private static func webAreaAncestor(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<24 {
            if attribute(kAXRoleAttribute, in: current) as? String == "AXWebArea" { return current }
            guard let parent = elementAttribute(kAXParentAttribute, in: current), !CFEqual(parent, current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func stringForRange(_ range: NSRange, in element: AXUIElement) -> String? {
        var range = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ name: String, in element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, in: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func attribute(_ name: String, in element: AXUIElement) -> CFTypeRef? {
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
