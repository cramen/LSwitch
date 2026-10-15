import Foundation

enum NativeDispatchPhase: Equatable, Sendable {
    case keyDown, keyUp, modifierDown, modifierUp

    var isDown: Bool { self == .keyDown || self == .modifierDown }
    var pairedUp: Self? {
        switch self {
        case .keyDown: return .keyUp
        case .modifierDown: return .modifierUp
        case .keyUp, .modifierUp: return nil
        }
    }
}

/// Системный адаптер снимает эти поля только с собственного подготовленного события. Unicode здесь нет.
struct NativeDispatchShape: Equatable, Sendable {
    let phase: NativeDispatchPhase
    let keyCode: UInt16
    let modifierFlags: UInt64
}

struct NativeDispatchPairShape: Sendable {
    let down: NativeDispatchShape
    let release: NativeDispatchShape

    var isValid: Bool { down.phase.pairedUp == release.phase && down.keyCode == release.keyCode }
}

struct NativeDispatchReservation: Equatable, Sendable {
    let marker: Int64
    fileprivate let registryIdentity: UUID

    fileprivate init(marker: Int64, registryIdentity: UUID) {
        self.marker = marker
        self.registryIdentity = registryIdentity
    }
}

struct NativeDispatchPairReservation: Sendable {
    let down: NativeDispatchReservation
    let release: NativeDispatchReservation
}

enum NativeDispatchPrevention: Equatable, Sendable { case generationClosed, downNotAdmitted, gateLost }
enum NativeDispatchRejection: Equatable, Sendable {
    case unknownMarker, foreignTarget, shapeMismatch, notSubmitted, duplicate
}

enum NativeDispatchStatus: Equatable, Sendable {
    case prepared
    case submitted(ConversionSafetySubmissionToken)
    case admitted(ConversionSafetySubmissionToken)
    case prevented(ConversionSafetySubmissionToken, NativeDispatchPrevention)
}

/// admitted — только ingress. Здесь намеренно нет receiverCompleted и разрешения replay.
enum NativeDispatchAdmission: Equatable, Sendable {
    case admitted(ConversionSafetySubmissionToken)
    case prevented(ConversionSafetySubmissionToken, NativeDispatchPrevention)
    case rejected(NativeDispatchRejection)
}

/// Один registry относится к одному operation и экземпляру процесса. Удаления/вытеснения записей нет.
final class NativeDispatchRegistry: @unchecked Sendable {
    static let maximumEntries = 256
    let scope: RecoveryOperationTarget

    private struct Entry {
        let shape: NativeDispatchShape
        let partner: Int64
        var status = NativeDispatchStatus.prepared
    }

    private let identity = UUID()
    private let lock = NSLock()
    private let markers: NativeDispatchMarkers
    private var entries: [Int64: Entry] = [:]
    private var usedTokens = Set<ConversionSafetySubmissionToken>()
    private var closed = false
    private var lost = false

    init?(scope: RecoveryOperationTarget, markers: NativeDispatchMarkers? = NativeDispatchMarkers.shared) {
        guard let markers else { return nil }
        self.scope = scope
        self.markers = markers
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Весь batch и его Up резервируются атомарно до первого submission. Не создаёт ledger tokens.
    func reservePairs(_ shapes: [NativeDispatchPairShape]) -> [NativeDispatchPairReservation]? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !shapes.isEmpty, shapes.count <= (Self.maximumEntries - entries.count) / 2,
              shapes.allSatisfy(\.isValid), let allocated = markers.reserve(shapes.count * 2) else { return nil }
        return shapes.enumerated().map { index, shape in
            let down = allocated[index * 2]
            let release = allocated[index * 2 + 1]
            entries[down] = Entry(shape: shape.down, partner: release)
            entries[release] = Entry(shape: shape.release, partner: down)
            return NativeDispatchPairReservation(
                down: .init(marker: down, registryIdentity: identity),
                release: .init(marker: release, registryIdentity: identity)
            )
        }
    }

    /// Вызывающий адаптер журналирует фактическую отправку отдельно; подготовка сама её не изображает.
    func registerSubmitted(
        _ reservation: NativeDispatchReservation, token: ConversionSafetySubmissionToken,
        scope expected: RecoveryOperationTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope, token.operation == scope.operation, !lost,
              reservation.registryIdentity == identity, var entry = entries[reservation.marker],
              entry.status == .prepared, !usedTokens.contains(token) else { return false }
        if entry.shape.phase.isDown {
            guard !closed else { return false }
        } else {
            guard canRegisterRelease(for: entry) else { return false }
        }
        entry.status = .submitted(token)
        entries[reservation.marker] = entry
        usedTokens.insert(token)
        return true
    }

    /// Это решение head callback: prevented требует фактического возврата nil владельцем адаптера.
    /// Нельзя вызывать его от таймера или только по факту closeGeneration.
    func observe(marker: Int64, shape: NativeDispatchShape, target: RecoveryProcessIdentity)
        -> NativeDispatchAdmission {
        lock.lock()
        defer { lock.unlock() }
        guard target == scope.target else { return .rejected(.foreignTarget) }
        guard var entry = entries[marker] else { return .rejected(.unknownMarker) }
        guard entry.shape == shape else { return .rejected(.shapeMismatch) }
        guard case .submitted(let token) = entry.status else {
            return .rejected(entry.status == .prepared ? .notSubmitted : .duplicate)
        }
        let prevention = prevention(for: entry)
        if let prevention {
            entry.status = .prevented(token, prevention)
            if prevention == .downNotAdmitted { closed = true }
        } else {
            entry.status = .admitted(token)
        }
        entries[marker] = entry
        return prevention.map { .prevented(token, $0) } ?? .admitted(token)
    }

    func status(of reservation: NativeDispatchReservation) -> NativeDispatchStatus? {
        lock.lock()
        defer { lock.unlock() }
        guard reservation.registryIdentity == identity else { return nil }
        return entries[reservation.marker]?.status
    }

    /// Только lookup метки. До него native adapter проверяет source PID; чужой payload/shape читать не нужно.
    func ownsReservedMarker(_ marker: Int64, target: RecoveryProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return target == scope.target && entries[marker] != nil
    }

    func closeGeneration() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func markLost() {
        lock.lock()
        lost = true
        closed = true
        lock.unlock()
    }

    private func prevention(for entry: Entry) -> NativeDispatchPrevention? {
        if lost { return .gateLost }
        if entry.shape.phase.isDown { return closed ? .generationClosed : nil }
        guard let partner = entries[entry.partner], case .admitted = partner.status else { return .downNotAdmitted }
        return nil
    }

    private func canRegisterRelease(for entry: Entry) -> Bool {
        guard let partner = entries[entry.partner] else { return false }
        switch partner.status {
        case .admitted: return true
        case .submitted: return !closed
        case .prepared, .prevented: return false
        }
    }
}
