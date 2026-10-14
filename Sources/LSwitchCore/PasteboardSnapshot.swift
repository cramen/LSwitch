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
