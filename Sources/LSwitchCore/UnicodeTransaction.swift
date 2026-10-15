import Foundation

@MainActor
final class UnicodeTransaction {
    let environment: UnicodeEnvironment
    let boundary: UnicodeReadBoundary
    let plan: AXReplacementPlan
    let keyboardPlan: KeyboardSelectionPlan?
    let packet: UnicodePreparedPacket
    var createdSelection = false
    var posted = false

    init(
        environment: UnicodeEnvironment, boundary: UnicodeReadBoundary,
        plan: AXReplacementPlan, keyboardPlan: KeyboardSelectionPlan?,
        packet: UnicodePreparedPacket
    ) {
        self.environment = environment
        self.boundary = boundary
        self.plan = plan
        self.keyboardPlan = keyboardPlan
        self.packet = packet
    }

    var request: ConversionRequest { boundary.request }
    var valid: Bool { boundary.isValid }

    func run() async -> ConversionResult {
        guard matches(text: plan.text, selection: plan.selection), request.beginMutation(), valid else {
            return .blocked
        }
        var initialObservation: UnicodeTextSnapshot?
        if let keyboardPlan, !plan.wasSelection {
            let attempt = await selectOwnRange(keyboardPlan)
            guard attempt.succeeded else { return await failed(.selectionFailed) }
            initialObservation = attempt.observation
        }
        let allowed = keyboardPlan?.ownedRanges ?? [plan.range]
        guard await settle(text: plan.text, selection: plan.range, allowed: allowed,
                           initialObservation: initialObservation) else {
            return await failed(.selectionChanged)
        }
        request.diagnostics?.mark(.selectionSettled)
        posted = packet.post {
            guard self.matches(text: self.plan.text, selection: self.plan.range), self.environment.canPost() else {
                return false
            }
            self.request.diagnostics?.mark(.unicodeDownRequested)
            return true
        }
        guard posted else { return await failed(.requestInvalid) }
        guard await confirm() else { return await failed(.textNotConfirmed) }
        request.diagnostics?.mark(.textConfirmed)
        return .success(plan.receipt)
    }

    func read(cleanup: Bool = false) -> UnicodeTextSnapshot? {
        boundary.read(cleanup: cleanup)
    }

    func matches(text: String, selection: NSRange, cleanup: Bool = false) -> Bool {
        guard let state = read(cleanup: cleanup) else { return false }
        return state.matches(text: text, selection: selection)
    }

    func settle(
        text: String, selection: NSRange, allowed: [NSRange], cleanup: Bool = false,
        initialObservation: UnicodeTextSnapshot? = nil
    ) async -> Bool {
        await UnicodeSelectionSettlement.wait(
            expected: (text, selection), allowedSelections: allowed,
            initialObservation: cleanup ? nil : initialObservation,
            canWait: { cleanup || !Task.isCancelled },
            readChecked: { self.read(cleanup: cleanup) }, pause: environment.pause
        )
    }

    private func selectOwnRange(_ selection: KeyboardSelectionPlan)
        async -> (succeeded: Bool, observation: UnicodeTextSnapshot?) {
        createdSelection = true
        request.diagnostics?.mark(.selectionKeyboardRequested)
        var observation: UnicodeTextSnapshot?
        let succeeded = await environment.sendSelection(
            .select(selection.characterCount), boundary.processID,
            { self.matches(text: self.plan.text, selection: self.plan.selection) },
            {
                // Повторный callback с partial/отказом не должен оставлять прежний exact seed.
                observation = nil
                guard let current = self.read(), current.text.utf16.elementsEqual(self.plan.text.utf16),
                      selection.ownedRanges.contains(current.selection) else { return false }
                if current.selection == self.plan.range { observation = current }
                return true
            }
        )
        if succeeded { request.diagnostics?.mark(.selectionApplied) }
        return (succeeded, succeeded ? observation : nil)
    }

    private func confirm() async -> Bool {
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        for _ in 0..<4 {
            guard !Task.isCancelled else { return false }
            await environment.pause()
            guard let state = read() else { return false }
            if state.text.utf16.elementsEqual(plan.resultingText.utf16) {
                if state.selection == plan.finalSelection {
                    return await settle(text: plan.resultingText, selection: plan.finalSelection,
                                        allowed: [plan.finalSelection], initialObservation: state)
                }
                if state.selection == inserted {
                    return await collapse(text: state.text, selection: inserted, caret: plan.finalSelection)
                }
                return false
            }
            guard state.matches(text: plan.text, selection: plan.range) else { return false }
        }
        return false
    }

    private func failed(_ reason: ConversionDiagnostics.Rejection) async -> ConversionResult {
        request.diagnostics?.reject(reason)
        await cleanup()
        return createdSelection || posted ? .failed : .blocked
    }

    private func cleanup() async {
        guard let state = read(cleanup: true) else { return }
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        if posted, state.matches(text: plan.resultingText, selection: inserted) {
            _ = await collapse(text: state.text, selection: inserted, caret: plan.finalSelection, cleanup: true)
        } else if createdSelection, let keyboardPlan,
                  state.text.utf16.elementsEqual(plan.text.utf16), keyboardPlan.ownedRanges.contains(state.selection) {
            // EOF делает Right безопасным при ignored и запоздалом batch. Readback не ACK.
            let recognized = { self.recognizesOriginalRange(keyboardPlan.ownedRanges, cleanup: true) }
            let sent = await environment.sendSelection(.collapse, boundary.processID, recognized, recognized)
            if sent {
                _ = await settle(text: plan.text, selection: plan.selection,
                                 allowed: keyboardPlan.ownedRanges, cleanup: true)
            }
        }
    }

    private func collapse(text: String, selection: NSRange, caret: NSRange, cleanup: Bool = false) async -> Bool {
        let sent = await environment.sendSelection(
            .collapse, boundary.processID,
            { self.matches(text: text, selection: selection, cleanup: cleanup) },
            {
                guard let current = self.read(cleanup: cleanup) else { return false }
                return current.text.utf16.elementsEqual(text.utf16)
                    && [selection, caret].contains(current.selection)
            }
        )
        guard sent else { return false }
        return await settle(text: text, selection: caret, allowed: [selection, caret], cleanup: cleanup)
    }

    private func recognizesOriginalRange(_ allowed: [NSRange], cleanup: Bool = false) -> Bool {
        guard let current = read(cleanup: cleanup) else { return false }
        return current.text.utf16.elementsEqual(plan.text.utf16) && allowed.contains(current.selection)
    }
}
