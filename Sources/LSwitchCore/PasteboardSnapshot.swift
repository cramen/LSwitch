import AppKit
import CryptoKit
import Foundation

/// Полный снимок содержимого pasteboard: все items и все типы данных
/// (спайк P0.3, design D5).
///
/// Инвариант clipboard-режима: после конвертации буфер бит-в-бит идентичен
/// исходному. Идентичность проверяется fingerprint'ом — SHA-256 по
/// `type + data` каждого элемента.
public struct PasteboardSnapshot: Equatable {

    public struct Item: Equatable {
        /// Данные по `NSPasteboard.PasteboardType.rawValue`. Тип без данных
        /// (ленивый promise) фиксируется с `nil` — восстановить его можно
        /// только декларацией типа без содержимого.
        public var dataByType: [String: Data?]
    }

    public let items: [Item]
}

public enum PasteboardService {

    public static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> PasteboardSnapshot.Item in
            var dataByType: [String: Data?] = [:]
            for type in item.types {
                dataByType[type.rawValue] = item.data(forType: type)
            }
            return PasteboardSnapshot.Item(dataByType: dataByType)
        }
        return PasteboardSnapshot(items: items)
    }

    public static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for snapshotItem in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in snapshotItem.dataByType {
                let type = NSPasteboard.PasteboardType(rawValue: rawType)
                if let data {
                    item.setData(data, forType: type)
                } else {
                    item.setString("", forType: type)
                }
            }
            pasteboard.writeObjects([item])
        }
    }

    /// SHA-256 (hex) по всем элементам буфера: типы каждого item
    /// сортируются для детерминированности, порядок items значим.
    public static func fingerprint(of pasteboard: NSPasteboard) -> String {
        var hasher = SHA256()
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            hasher.update(data: Data("item:\(index)".utf8))
            for type in item.types.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.update(data: Data(type.rawValue.utf8))
                if let data = item.data(forType: type) {
                    hasher.update(data: data)
                }
                hasher.update(data: Data([0]))
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
