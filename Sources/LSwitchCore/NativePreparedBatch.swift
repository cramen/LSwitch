import CoreGraphics
import Darwin

/// Подготовка не отправляет события и не создаёт ledger tokens. Все пары резервируются вместе.
/// Хранятся частные копии: изменение исходного CGEvent не меняет будущую команду.
final class NativePreparedBatch {
    struct Packet {
        let shape: NativeDispatchShape
        let reservation: NativeDispatchReservation
        let partnerIndex: Int
        fileprivate let event: CGEvent

        /// Копия для одноразового sender. Сам batch не является разрешением отправки.
        func copyEvent() -> CGEvent? {
            guard let copy = event.copy(), Self.matches(copy, shape: shape, marker: reservation.marker) else {
                return nil
            }
            return copy
        }

        fileprivate static func matches(_ event: CGEvent, shape: NativeDispatchShape, marker: Int64) -> Bool {
            NativeDispatchShape.readKeyboard(event) == shape
                && event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
                && event.getIntegerValueField(.eventSourceUserData) == marker
        }
    }

    let packets: [Packet]
    let scope: RecoveryOperationTarget

    private init(packets: [Packet], scope: RecoveryOperationTarget) {
        self.packets = packets
        self.scope = scope
    }

    static func prepare(command: ClipboardCommand, gate: RecipientGateState) -> NativePreparedBatch? {
        if case .selectCharacters(let count) = command {
            guard count > 0, count <= (NativeDispatchRegistry.maximumEntries - 2) / 2 else { return nil }
        }
        guard let events = KeyboardEmitter.events(for: command) else { return nil }
        return prepare(events, gate: gate)
    }

    static func prepare(_ events: [CGEvent], gate: RecipientGateState) -> NativePreparedBatch? {
        guard !events.isEmpty, events.count <= NativeDispatchRegistry.maximumEntries else { return nil }
        let copies = events.compactMap { $0.copy() }
        guard copies.count == events.count else { return nil }
        let shapes = copies.compactMap { NativeDispatchShape.readKeyboard($0) }
        guard shapes.count == copies.count, let pairs = pairIndices(shapes) else { return nil }
        let pairShapes = pairs.map { NativeDispatchPairShape(down: shapes[$0.down], release: shapes[$0.release]) }
        guard let reservations = gate.reservePairs(pairShapes, scope: gate.scope) else { return nil }
        var indexed: [Int: Packet] = [:]
        for (pair, reservation) in zip(pairs, reservations) {
            indexed[pair.down] = packet(copies[pair.down], shape: shapes[pair.down],
                                       reservation: reservation.down, partner: pair.release)
            indexed[pair.release] = packet(copies[pair.release], shape: shapes[pair.release],
                                          reservation: reservation.release, partner: pair.down)
        }
        let packets = copies.indices.compactMap { indexed[$0] }
        // При неудачном roundtrip reservation остаётся tombstone; повторного использования marker нет.
        guard packets.count == copies.count else { return nil }
        return .init(packets: packets, scope: gate.scope)
    }

    private static func packet(
        _ event: CGEvent, shape: NativeDispatchShape,
        reservation: NativeDispatchReservation, partner: Int
    ) -> Packet? {
        // Не меняем Unicode: native Cmd+C и Unicode text packet сохраняют исходное содержимое.
        event.setIntegerValueField(.eventSourceUserData, value: reservation.marker)
        if event.getIntegerValueField(.eventSourceUserData) != reservation.marker {
            guard let source = CGEventSource(event: event) else { return nil }
            source.userData = reservation.marker
            event.setSource(source)
        }
        guard Packet.matches(event, shape: shape, marker: reservation.marker) else { return nil }
        return .init(shape: shape, reservation: reservation, partnerIndex: partner, event: event)
    }

    private static func pairIndices(_ shapes: [NativeDispatchShape]) -> [(down: Int, release: Int)]? {
        var pressed: [UInt16: Int] = [:]
        var pairs: [(down: Int, release: Int)] = []
        for (index, shape) in shapes.enumerated() {
            if shape.phase.isDown {
                guard pressed[shape.keyCode] == nil else { return nil }
                pressed[shape.keyCode] = index
            } else {
                guard let down = pressed.removeValue(forKey: shape.keyCode),
                      shapes[down].phase.pairedUp == shape.phase else { return nil }
                pairs.append((down: down, release: index))
            }
        }
        guard pressed.isEmpty else { return nil }
        return pairs
    }
}
