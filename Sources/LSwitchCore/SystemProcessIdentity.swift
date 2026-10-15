import Darwin
import Foundation

/// Системное чтение вне event-tap callback. PID без времени рождения не подтверждает экземпляр процесса.
enum SystemProcessIdentity {
    static func read(processID: Int32) -> RecoveryProcessIdentity? {
        guard processID > 0 else { return nil }
        var information = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let received = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &information, expected)
        guard received == expected, information.pbi_pid == UInt32(processID),
              information.pbi_status != UInt32(SZOMB) else { return nil }
        return RecoveryProcessIdentity(
            processID: processID, birthSeconds: information.pbi_start_tvsec,
            birthMicroseconds: information.pbi_start_tvusec
        )
    }

    /// Повторная проверка не даёт долговременной lease и не заменяет process-exit latch адаптера.
    static func isCurrent(_ identity: RecoveryProcessIdentity) -> Bool {
        read(processID: identity.processID) == identity
    }
}
