import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodeReadBoundaryTests: XCTestCase {
    private enum Fault: CaseIterable { case focus, secure, document, source, lease, revision }

    func testEarlyInvalidInitialCapturePerformsNoRawReads() async {
        for invalidTarget in [false, true] {
            let editor = UnicodeTestEditor("ghbdtn ")
            if invalidTarget { editor.contextValid = false } else { editor.requestValid = false }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(editor.identityReads, 0)
            XCTAssertEqual(editor.reads, 0)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertTrue(editor.commands.isEmpty)
        }
    }

    func testInitialIdentityReadRechecksFocusSecureSourceLeaseAndRevision() async {
        for fault in Fault.allCases where fault != .document {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.onIdentityRead = { self.invalidate(fault, in: editor) }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .blocked, "\(fault)")
            XCTAssertEqual(editor.identityReads, 1)
            XCTAssertEqual(editor.reads, 0)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertEqual(editor.beginCount, 0)
            XCTAssertEqual(editor.downCount, 0)
        }
    }

    func testFaultInsideLaterIdentityReadNeverAuthorizesRawTextRead() async {
        for fault in Fault.allCases {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.onIdentityRead = {
                if editor.identityReads == 2 { self.invalidate(fault, in: editor) }
            }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .blocked, "\(fault)")
            XCTAssertGreaterThan(editor.identityReads, 1)
            XCTAssertEqual(editor.reads, 0)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertTrue(editor.commands.isEmpty)
        }
    }

    func testFaultInsideInitialRawSnapshotDiscardsItsReturnedState() async {
        for fault in Fault.allCases {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.onRead = { self.invalidate(fault, in: editor) }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .blocked, "\(fault)")
            XCTAssertEqual(editor.reads, 1)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertEqual(editor.beginCount, 0)
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.text, "ghbdtn ")
        }
    }

    func testFocusOrProtectionChangeDuringMetadataStopsBeforeFirstPayloadRead() async {
        for fault in [Fault.focus, .secure] {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.afterMetadataRead = { self.invalidate(fault, in: editor) }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(editor.reads, 1)
            XCTAssertEqual(editor.valueReads, 0)
            XCTAssertEqual(editor.coordinateReads, 0)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertEqual(editor.downCount, 0)
        }
    }

    func testFocusOrProtectionChangeAfterValueStopsFurtherSensitiveReads() async {
        for fault in [Fault.focus, .secure] {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.afterValueRead = { self.invalidate(fault, in: editor) }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(editor.valueReads, 1)
            XCTAssertEqual(editor.coordinateReads, 0)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertEqual(editor.downCount, 0)
        }
    }

    func testFaultInsideRawSnapshotAfterAwaitCannotReachDownOrForeignCleanup() async {
        for fault in Fault.allCases {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.onPause = { count in
                if count == 1 { editor.onRead = { self.invalidate(fault, in: editor) } }
            }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .failed, "\(fault)")
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.text, "ghbdtn ")
            switch fault {
            case .focus, .secure, .document:
                XCTAssertEqual(editor.commands, [.select(7)])
            case .source, .lease, .revision:
                XCTAssertEqual(editor.commands, [.select(7), .collapse])
                XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
            }
        }
    }

    func testReceiptGuardRechecksTargetAfterItsRawIdentityRead() async {
        for fault in [Fault.focus, .secure, .document] {
            let editor = UnicodeTestEditor("ghbdtn ")
            let converted = await editor.converter().perform(editor.request())
            guard case .success(let receipt) = converted else { XCTFail("Нет receipt"); return }
            editor.onIdentityRead = { self.invalidate(fault, in: editor) }
            XCTAssertEqual(receipt.targetIsCurrent?(), false, "\(fault)")
            let undo = ConversionRequest(expectedWord: "привет", trailingText: " ",
                                         replacement: "ghbdtn", useSelection: false)
                .checkingTarget(receipt.targetIsCurrent)
            let result = await editor.converter().perform(undo)
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(editor.downCount, 1)
            XCTAssertEqual(editor.text, "привет ")
        }
    }

    func testCancelledReadStillAllowsOnlySameTargetCleanup() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onPause = { count in
            if count == 1 {
                editor.onRead = {
                    editor.onRead = nil
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let task = Task { await editor.converter().perform(editor.request()) }
        let result = await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
        editor.type("next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    private func invalidate(_ fault: Fault, in editor: UnicodeTestEditor) {
        switch fault {
        case .focus: editor.contextValid = false
        case .secure: editor.protectedField = true
        case .document: editor.document = "fixture:other"
        case .source: editor.source = nil
        case .lease: editor.leaseValid = false
        case .revision: editor.revision += 1
        }
    }
}
