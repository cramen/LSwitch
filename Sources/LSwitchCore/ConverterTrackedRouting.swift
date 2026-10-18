import Foundation

extension Converter {
    func performTracked(
        _ request: ConversionRequest, bundleID: String, session: ConversionRecoverySession
    ) async -> TrackedEngineResult {
        guard request.safetyLedger === session.ledger, request.isValid() else {
            return .init(result: .blocked, mechanism: .none)
        }
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
        let engine: any ConversionEngine
        if let bound = session.boundAXEngine {
            engine = bound
        } else {
            guard session.ledger.profileBinding == nil else { return .init(result: .blocked, mechanism: .none) }
            engine = makeAXEngine()
        }
        request.diagnostics?.mark(.engineStarted, mechanism: .accessibility)
        let result = await engine.perform(request)
        if case .unavailable = result, session.permitsFallback, session.allows(.clipboard) {
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
