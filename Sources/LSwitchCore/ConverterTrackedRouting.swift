import Foundation

extension Converter {
    func performTracked(
        _ request: ConversionRequest, bundleID: String, session: ConversionRecoverySession
    ) async -> TrackedEngineResult {
        guard request.safetyLedger === session.ledger, request.isValid() else {
            return .init(result: .blocked, mechanism: .none)
        }
        let mode = localProfiles?.mode(for: bundleID) ?? .builtIn
        switch mode {
        case .disabled: return .init(result: .blocked, mechanism: .none)
        case .keyboardClipboard:
            guard session.allows(.clipboard) else { return .init(result: .blocked, mechanism: .none) }
            return await trackedClipboard(request)
        case .accessibility:
            guard !AppProfiles().prefersClipboard(bundleID: bundleID), session.allows(.accessibility) else {
                return .init(result: .blocked, mechanism: .none)
            }
            return await trackedAccessibility(request, session: session, allowFallback: false)
        case .builtIn: return await trackedBuiltIn(request, bundleID: bundleID, session: session)
        }
    }

    private func trackedBuiltIn(
        _ request: ConversionRequest, bundleID: String, session: ConversionRecoverySession
    ) async -> TrackedEngineResult {
        if session.allows(.unicode), let engine = makeUnicodeEngine?(bundleID) {
            request.diagnostics?.mark(.engineStarted, mechanism: .unicode)
            return .init(result: await engine.perform(request), mechanism: .unicode)
        }
        if session.allows(.clipboard), modeCache[bundleID] == .clipboard || prefersClipboard(bundleID) {
            return await trackedClipboard(request)
        }
        guard session.allows(.accessibility) else {
            if session.allows(.clipboard) { return await trackedClipboard(request) }
            return .init(result: .blocked, mechanism: .none)
        }
        return await trackedAccessibility(request, session: session, allowFallback: true)
    }

    private func trackedAccessibility(
        _ request: ConversionRequest, session: ConversionRecoverySession, allowFallback: Bool
    ) async -> TrackedEngineResult {
        let engine: any ConversionEngine
        if let bound = session.boundAXEngine {
            engine = bound
        } else {
            guard session.ledger.profileBinding == nil else { return .init(result: .blocked, mechanism: .none) }
            engine = makeAXEngine()
        }
        request.diagnostics?.mark(.engineStarted, mechanism: .accessibility)
        let result = await engine.perform(request)
        if case .unavailable = result, allowFallback, session.permitsFallback, session.allows(.clipboard) {
            return await trackedClipboard(request)
        }
        return .init(result: result, mechanism: .accessibility)
    }

    private func trackedClipboard(_ request: ConversionRequest) async -> TrackedEngineResult {
        guard request.isValid() else { return .init(result: .blocked, mechanism: .clipboard) }
        request.diagnostics?.mark(.engineStarted, mechanism: .clipboard)
        return .init(result: await makeClipboardEngine().perform(request), mechanism: .clipboard)
    }
}
