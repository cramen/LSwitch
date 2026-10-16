import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class AXProfileFixture {
    let access: AXSafetyTestAccess
    var window = AXUIElementCreateApplication(200)
    var process: RecoveryProcessIdentity
    var document = "fixture:document-a"
    var applicationVersion = "1.19"
    var applicationBuild = "404"
    var systemVersion = "14.5"
    var systemBuild = "23F79"
    var role = kAXTextAreaRole
    var countOverride: Int?
    var missingSnapshot = false
    var valid = true
    var activeSource = UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true)
    var snapshotReads = 0
    var duringRead: (() -> Bool) -> Void = { _ in }

    init(_ text: String = "ghbdtn ") throws {
        access = AXSafetyTestAccess(text)
        process = try XCTUnwrap(RecoveryProcessIdentity(processID: 100, birthSeconds: 1, birthMicroseconds: 0))
    }

    var environment: AXProfileEnvironment {
        .init(activeSource: { self.activeSource },
              focusedElement: { self.access.focusedElement() }, isProtected: { self.access.isProtected($0) },
              context: { _ in
            .init(process: self.process, window: self.window, document: self.document,
                  bundleIdentifier: "com.apple.TextEdit", applicationVersion: self.applicationVersion,
                  applicationBuild: self.applicationBuild, systemVersion: self.systemVersion,
                  systemBuild: self.systemBuild, role: self.role)
        }, snapshot: { element, canRead in
            self.snapshotReads += 1
            guard canRead() else { return nil }
            self.duringRead(canRead)
            guard canRead(), !self.missingSnapshot else { return nil }
            return AXProfileSnapshotReader(readCount: {
                self.countOverride ?? self.access.model.value.utf16.count
            }, readText: { range in
                XCTAssertEqual(range.location, 0)
                XCTAssertLessThanOrEqual(range.length, AXProfileSnapshot.maximumUTF16Units)
                return self.access.text(in: element)
            }, readSelection: { self.access.selection(in: element) }).read(canRead: canRead)
        })
    }

    func profile() -> AXObservationProfile? {
        .prepareTextEdit(element: access.model.element, environment: environment)
    }

    func prepare() throws -> AXProfileTestOperation {
        let profile = try XCTUnwrap(profile())
        let ledger = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        return .init(profile: profile, ledger: ledger,
                     converter: AXTextConverter(access: access, observationProfile: profile))
    }

    func request(_ ledger: ConversionSafetyLedger, replacement: String? = nil) -> ConversionRequest {
        ConversionRequest(expectedWord: replacement == nil ? "ghbdtn" : "привет", trailingText: " ",
                          replacement: replacement, useSelection: false, safetyLedger: ledger, isValid: { self.valid })
    }
}

struct AXProfileTestOperation {
    let profile: AXObservationProfile
    let ledger: ConversionSafetyLedger
    let converter: AXTextConverter
}
