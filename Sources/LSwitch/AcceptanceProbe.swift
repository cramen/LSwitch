import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import Security

/// Ранний CLI-dispatch для отдельных LSwitchProbe.app. Выдачу TCC и управление UI выполняет оператор.
@MainActor
enum AcceptanceProbe {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let isProbe = (Bundle.main.bundleIdentifier ?? "").hasPrefix("ru.cramen.lswitch.probe.")
        let index = arguments.firstIndex(of: "--acceptance-probe")
        guard index != nil || isProbe else { return nil }
        let mode: String
        if let index, arguments.indices.contains(index + 1) {
            mode = arguments[index + 1]
        } else {
            // Случайный запуск отдельного бандла не должен запускать продуктовый перехват.
            mode = "metadata"
        }
        var report = metadata()
        report["mode"] = mode
        report["implicitMetadata"] = index == nil
        let result: [String: Any]
        if mode != "metadata", !isProbe {
            result = ["ok": false, "error": "Требуется отдельная identity ru.cramen.lswitch.probe.*"]
        } else {
            result = execute(mode: mode, arguments: arguments)
        }
        report["result"] = result
        printReport(report)
        return result["ok"] as? Bool == true ? 0 : 1
    }

    static func value(_ flag: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Как в SystemAXTextAccess: ограничение IPC задаётся для конкретного объекта.
    static func limitMessaging(_ element: AXUIElement) -> AXError {
        AXUIElementSetMessagingTimeout(element, 0.1)
    }

    private static func execute(mode: String, arguments: [String]) -> [String: Any] {
        switch mode {
        case "metadata": return ["ok": true]
        case "keyup": return AcceptanceEventTapProbe.run()
        case "ax": return AcceptanceAXProbe.run(arguments: arguments)
        case "file-promise": return AcceptanceFilePromiseProbe.run()
        case "clipboard-unresolved": return AcceptanceClipboardProbe.run(mode: mode, fixtures: nil)
        case "clipboard", "clipboard-lazy":
            guard let path = value("--fixtures", arguments: arguments), path.hasPrefix("/") else {
                return ["ok": false, "error": "Требуется абсолютный --fixtures"]
            }
            return AcceptanceClipboardProbe.run(mode: mode, fixtures: URL(fileURLWithPath: path))
        default:
            return ["ok": false, "error": "Неизвестный режим приёмочного пробника"]
        }
    }

    private static func metadata() -> [String: Any] {
        let sandbox = entitlement("com.apple.security.app-sandbox") as? Bool ?? false
        let systemWide = AXUIElementCreateSystemWide()
        // По AXUIElement.h system-wide объект задаёт также default timeout всего процесса.
        let timeoutStatus = limitMessaging(systemWide)
        var focusedApplication: CFTypeRef?
        let axStatus: AXError
        if timeoutStatus == .success {
            axStatus = AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApplication
            )
        } else {
            axStatus = timeoutStatus
        }
        var report: [String: Any] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "unbundled",
            "bundlePath": Bundle.main.bundleURL.path,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sandbox": sandbox,
            "axTrusted": AXIsProcessTrusted(),
            "axFocusedApplicationResult": axStatus.rawValue,
            "axFocusedApplicationAttempted": timeoutStatus == .success,
            "axMessagingTimeoutSeconds": 0.1,
            "axMessagingTimeoutResult": timeoutStatus.rawValue,
            "listenPreflight": CGPreflightListenEventAccess(),
            "postPreflight": CGPreflightPostEventAccess(),
            "requestedPermissions": false,
            "generalClipboardTouched": false
        ]
        let keys = [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.temporary-exception.files.absolute-path.read-only",
            "com.apple.security.temporary-exception.accessibility",
            "com.apple.security.temporary-exception.mach-lookup.global-name"
        ]
        for key in keys {
            if let value = entitlement(key) { report[key] = value }
        }
        if let executable = Bundle.main.executableURL, let data = try? Data(contentsOf: executable) {
            report["signedExecutableSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return report
    }

    private static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    private static func printReport(_ report: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
              ) else {
            print("{\"result\":{\"ok\":false,\"error\":\"report-encoding\"}}")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
