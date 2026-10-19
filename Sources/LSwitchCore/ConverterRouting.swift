import Foundation

extension Converter {
    func perform(_ request: ConversionRequest, bundleID: String) async -> ConversionResult {
        guard request.isValid() else { return .blocked }
        switch localProfiles?.mode(for: bundleID) ?? .builtIn {
        case .disabled: return .blocked
        case .accessibility:
            guard !AppProfiles().prefersClipboard(bundleID: bundleID) else { return .blocked }
            request.diagnostics?.mark(.engineStarted, mechanism: .accessibility)
            return await makeAXEngine().perform(request)
        case .keyboardClipboard:
            request.diagnostics?.mark(.engineStarted, mechanism: .clipboard)
            return await makeClipboardEngine().perform(request)
        case .builtIn: break
        }
        return await performBuiltIn(request, bundleID: bundleID)
    }

    private func performBuiltIn(_ request: ConversionRequest, bundleID: String) async -> ConversionResult {
        if let engine = makeUnicodeEngine?(bundleID) {
            request.diagnostics?.mark(.engineStarted, mechanism: .unicode)
            return await engine.perform(request)
        }
        if modeCache[bundleID] == .clipboard || prefersClipboard(bundleID) {
            request.diagnostics?.mark(.engineStarted, mechanism: .clipboard)
            return await makeClipboardEngine().perform(request)
        }
        request.diagnostics?.mark(.engineStarted, mechanism: .accessibility)
        let result = await makeAXEngine().perform(request)
        switch result {
        case .success:
            modeCache[bundleID] = .accessibility
            return result
        case .unavailable:
            guard request.isValid() else { return .blocked }
            request.diagnostics?.mark(.engineStarted, mechanism: .clipboard)
            let fallback = await makeClipboardEngine().perform(request)
            if case .success = fallback { modeCache[bundleID] = .clipboard }
            return fallback
        case .blocked, .failed:
            return result
        }
    }
}
