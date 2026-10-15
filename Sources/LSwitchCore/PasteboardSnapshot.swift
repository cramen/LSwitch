import AppKit
import CryptoKit
import Foundation

/// Полный снимок содержимого pasteboard: все items и все типы данных
/// (спайк P0.3, design D5).
///
/// Инвариант clipboard-режима: после конвертации буфер бит-в-бит идентичен
/// исходному. Идентичность проверяется fingerprint'ом — SHA-256 по
/// `type + data` каждого элемента.
public struct PasteboardSnapshot: Equatable, Codable, Sendable {

    public struct Item: Equatable, Codable, Sendable {
        /// Тип без данных фиксируется как существующий ключ с nil, а не удаляется.
        /// Такой снимок нельзя восстановить без исходного поставщика.
        public var dataByType: [String: Data?]
    }

    public let items: [Item]
    public let containsFilePromises: Bool

    public init(items: [Item], containsFilePromises: Bool = false) {
        self.items = items
        self.containsFilePromises = containsFilePromises
    }

    /// Только материализованные Data без известных file-promise контрактов можно переопубликовать.
    public var isRestorable: Bool {
        !containsFilePromises && items.allSatisfy { item in
            item.dataByType.values.allSatisfy { $0 != nil }
        }
    }
}

public enum PasteboardService {

    public static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        let declaredTypes = pasteboardItems.map(\.types)
        let containsFilePromises = declaredTypes.contains { types in
            types.contains { promiseTypes.contains($0.rawValue) }
        }
        let items = zip(pasteboardItems, declaredTypes).map { item, types -> PasteboardSnapshot.Item in
            var dataByType: [String: Data?] = [:]
            for type in types {
                // Отказываем до data() любого item, а не после материализации promise.
                dataByType[type.rawValue] = .some(containsFilePromises ? nil : item.data(forType: type))
            }
            return PasteboardSnapshot.Item(dataByType: dataByType)
        }
        return PasteboardSnapshot(items: items, containsFilePromises: containsFilePromises)
    }

    /// Невосстановимое обещание не превращается в пустую строку и не уничтожает текущий clipboard.
    @discardableResult
    public static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) -> Bool {
        guard snapshot.isRestorable else { return false }
        var items: [NSPasteboardItem] = []
        for snapshotItem in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in snapshotItem.dataByType {
                let type = NSPasteboard.PasteboardType(rawValue: rawType)
                guard let data, item.setData(data, forType: type) else { return false }
            }
            items.append(item)
        }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }

    /// SHA-256 по однозначно разделённым полям снимка. Длины отделяют type от data,
    /// наличие данных различает nil и пустой Data; порядок items остаётся значимым.
    public static func fingerprint(of pasteboard: NSPasteboard) -> String {
        var hasher = SHA256()
        let items = pasteboard.pasteboardItems ?? []
        appendCount(items.count, to: &hasher)
        for item in items {
            let types = item.types.sorted(by: { $0.rawValue < $1.rawValue })
            appendCount(types.count, to: &hasher)
            for type in types {
                let typeData = Data(type.rawValue.utf8)
                appendCount(typeData.count, to: &hasher)
                hasher.update(data: typeData)
                if let data = item.data(forType: type) {
                    hasher.update(data: Data([1]))
                    appendCount(data.count, to: &hasher)
                    hasher.update(data: data)
                } else {
                    hasher.update(data: Data([0]))
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func appendCount(_ count: Int, to hasher: inout SHA256) {
        var encoded = UInt64(count).bigEndian
        withUnsafeBytes(of: &encoded) { hasher.update(data: Data($0)) }
    }
}
