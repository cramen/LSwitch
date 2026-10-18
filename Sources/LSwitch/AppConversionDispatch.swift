import AppKit
import LSwitchCore

/// App завершает outcome перед логическим хвостом. В обычном режиме сохраняется прежний путь.
@MainActor
final class AppConversionDispatch {
    #if DEBUG
    private var pilot: AppRecoveryPilot?
    #endif

    var factory: Converter.RecoverySessionFactory? {
        #if DEBUG
        guard let pilot else { return nil }
        return { await pilot.runtime.makeSession($0) }
        #else
        return nil
        #endif
    }

    var owner: ConversionRecoveryOwner? {
        #if DEBUG
        return pilot?.runtime.owner
        #else
        return nil
        #endif
    }

    func configure(
        eventTap: @escaping @MainActor () -> EventTapCore?,
        currentSafety: @escaping @MainActor () -> Bool,
        onAvailability: @escaping (Bool) -> Void
    ) -> Bool {
        #if DEBUG
        let prefix = "--recovery-textedit-pilot="
        let values = CommandLine.arguments.filter { $0.hasPrefix("--recovery-textedit-pilot") }
        let faults = CommandLine.arguments.filter { $0.hasPrefix("--recovery-textedit-fault") }
        guard !values.isEmpty else { return faults.isEmpty }
        guard values.count == 1, let value = values.first, value.hasPrefix(prefix), pilot == nil else { return false }
        let path = String(value.dropFirst(prefix.count))
        guard path.hasPrefix("/"), path.utf8.count <= 4096, let fault = faultMode(faults) else { return false }
        let prepared = AppRecoveryPilot(testDocument: URL(fileURLWithPath: path), faultMode: fault,
                                       eventTap: eventTap, currentSafety: currentSafety)
        prepared.onAvailabilityChange = onAvailability
        pilot = prepared
        #else
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--recovery-textedit-") }) { return false }
        #endif
        return true
    }

    #if DEBUG
    private func faultMode(_ values: [String]) -> TextEditRecoveryFaultMode? {
        guard !values.isEmpty else { return TextEditRecoveryFaultMode.none }
        let prefix = "--recovery-textedit-fault="
        guard values.count == 1, let value = values.first, value.hasPrefix(prefix) else { return nil }
        return TextEditRecoveryFaultMode(rawValue: String(value.dropFirst(prefix.count)))
    }
    #endif

    func perform(
        operation: @MainActor () async -> Converter.Outcome,
        applyOutcome: @escaping @MainActor @Sendable (Converter.Outcome) -> Void,
        reset: @escaping @MainActor @Sendable () -> Void,
        consume: @escaping @MainActor @Sendable (RawKeyEvent) -> Void
    ) async {
        #if DEBUG
        if let pilot {
            await pilot.perform(operation: operation, actions: .init(
                applyOutcome: applyOutcome, reset: reset, consume: consume
            ))
            return
        }
        #endif
        applyOutcome(await operation())
    }

    func focusChanged() {
        #if DEBUG
        pilot?.invalidate(.focusChanged)
        #endif
    }

    func permissionsLost() {
        #if DEBUG
        pilot?.invalidate(.permissionLost)
        #endif
    }

    func tapLost() {
        #if DEBUG
        pilot?.invalidate(.tapLost)
        #endif
    }

    func disabled() {
        #if DEBUG
        pilot?.invalidate(.off)
        #endif
    }

    func showRecovery() {
        #if DEBUG
        pilot?.show()
        #endif
    }

    /// true означает отложенный ответ NSApplication, а не согласие на удаление записи.
    func requestQuit(completion: @escaping (Bool) -> Void) -> Bool {
        #if DEBUG
        guard let pilot else { return false }
        pilot.requestQuit(completion: completion)
        return true
        #else
        return false
        #endif
    }
}
