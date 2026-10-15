import Foundation

/// Выбор транспорта делается до команды: неподтверждённый Paste никогда не повторяется.
@MainActor
struct ClipboardCommandTransport {
    struct Target: Equatable {
        let processID: pid_t
        let bundleID: String?
    }

    var forceKeyboard = false
    var currentTarget: () -> Target?
    var prepareMenu: (pid_t, @escaping @MainActor () -> Bool) -> Void
    var invokeMenu: (ClipboardCommand, pid_t, @escaping @MainActor () -> Bool) -> MenuCommand.Outcome
    var commitMenu: (
        pid_t, @escaping @MainActor () async -> Bool,
        @escaping @MainActor () -> Bool, @escaping @MainActor () -> Bool
    ) async -> MenuCommand.Outcome
    var sendKeyboard: (
        ClipboardCommand, pid_t, @escaping @MainActor () -> Bool, @escaping @MainActor () -> Bool
    ) async -> Bool

    func prepare(isValid: @escaping @MainActor () -> Bool) {
        guard isValid(), let target = currentTarget(), target.processID > 0,
              !usesKeyboard(target) else { return }
        prepareMenu(target.processID, { isValid() && self.currentTarget() == target })
    }

    func send(_ command: ClipboardCommand, isValid: @escaping @MainActor () -> Bool) async -> Bool {
        guard isValid(), let target = currentTarget(), target.processID > 0 else { return false }
        let valid = { isValid() && self.currentTarget() == target }
        if !usesKeyboard(target) {
            switch invokeMenu(command, target.processID, valid) {
            case .performed: return valid()
            case .failed: return false
            case .unavailable: break
            }
        }
        return await sendKeyboard(command, target.processID, valid, { true }) && valid()
    }

    func commitPaste(
        select: @escaping @MainActor () async -> Bool,
        check: @escaping @MainActor () -> Bool,
        isValid: @escaping @MainActor () -> Bool
    ) async -> MenuCommand.Outcome {
        guard isValid(), let target = currentTarget(), target.processID > 0 else { return .failed }
        let valid = { isValid() && self.currentTarget() == target }
        guard usesKeyboard(target) else {
            return await commitMenu(target.processID, select, check, valid)
        }
        guard valid(), await select(), valid(), check(), valid() else { return .failed }
        let sent = await sendKeyboard(.paste, target.processID, valid, { valid() && check() })
        return sent && valid() ? .performed : .failed
    }

    private func usesKeyboard(_ target: Target) -> Bool {
        forceKeyboard || AppProfiles.prefersKeyboardCommands(bundleID: target.bundleID)
    }
}
