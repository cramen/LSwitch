import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionHotkeyTests: XCTestCase {
    private let custom = ConversionHotkey(keyCode: 40, modifiers: CGEventFlags.maskControl.rawValue)

    func testOptionSpaceValidationPersistenceAndDetection() throws {
        let hotkey = ConversionHotkey(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue)
        XCTAssertTrue(hotkey.isValid)
        XCTAssertEqual(hotkey.title, "⌥Пробел")
        XCTAssertFalse(ConversionHotkey(keyCode: 49, modifiers: 0).isValid)
        XCTAssertFalse(ConversionHotkey(keyCode: 49, modifiers: CGEventFlags.maskShift.rawValue).isValid)
        let name = "LSwitch.OptionSpaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.conversionHotkey = hotkey
        XCTAssertEqual(SettingsStore(defaults: defaults).conversionHotkey, hotkey)
        var detector = ConversionHotkeyDetector()
        let down = RawKeyEvent(type: .keyDown, keyCode: 49, characters: "\u{00A0}",
                               modifierFlags: hotkey.modifiers, isSynthetic: false, timestamp: 100)
        XCTAssertEqual(detector.handle(down, hotkey: hotkey), .trigger)
        detector.resetSequence()
        XCTAssertEqual(detector.handle(down, hotkey: hotkey), .consumed)
        let release = RawKeyEvent(type: .keyUp, keyCode: 49, characters: "",
                                  modifierFlags: 0, isSynthetic: false, timestamp: 200)
        _ = detector.handle(release, hotkey: hotkey)
        let plain = RawKeyEvent(type: .keyDown, keyCode: 49, characters: " ",
                                modifierFlags: 0, isSynthetic: false, timestamp: 300)
        XCTAssertEqual(detector.handle(plain, hotkey: hotkey), .none)
        _ = detector.handle(release, hotkey: hotkey)
        XCTAssertEqual(detector.handle(down, hotkey: hotkey), .trigger)
    }

    func testValidationAndPhysicalKeyTitle() {
        XCTAssertTrue(custom.isValid)
        XCTAssertEqual(custom.title, "⌃K")
        XCTAssertTrue(ConversionHotkey.doubleShift.isValid)
        XCTAssertFalse(ConversionHotkey(keyCode: 40, modifiers: 0).isValid)
        XCTAssertFalse(ConversionHotkey(keyCode: 40, modifiers: CGEventFlags.maskAlternate.rawValue).isValid)
        XCTAssertFalse(ConversionHotkey(keyCode: 56, modifiers: custom.modifiers).isValid)
        XCTAssertFalse(ConversionHotkey(keyCode: nil, modifiers: custom.modifiers).isValid)
        XCTAssertFalse(ConversionHotkey(keyCode: 40, modifiers: custom.modifiers | 1).isValid)
    }

    func testRepeatResetAndNextPhysicalPress() {
        var detector = ConversionHotkeyDetector()
        XCTAssertEqual(detector.handle(event(.keyDown), hotkey: custom), .trigger)
        detector.resetSequence()
        XCTAssertEqual(detector.handle(event(.keyDown), hotkey: custom), .consumed)
        XCTAssertEqual(detector.handle(event(.keyUp), hotkey: custom), .none)
        XCTAssertEqual(detector.handle(event(.keyDown, characters: "л"), hotkey: custom), .trigger)
    }

    func testWrongModifiersSyntheticAndChangedConfiguration() {
        var detector = ConversionHotkeyDetector()
        XCTAssertEqual(detector.handle(event(.keyDown, synthetic: true), hotkey: custom), .none)
        XCTAssertEqual(detector.handle(event(.keyDown, flags: custom.modifiers | CGEventFlags.maskShift.rawValue),
                                       hotkey: custom), .none)
        _ = detector.handle(event(.keyUp), hotkey: custom)
        XCTAssertEqual(detector.handle(event(.keyDown), hotkey: custom), .trigger)
        let changed = ConversionHotkey(keyCode: 40, modifiers: CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(detector.handle(event(.keyDown, flags: changed.modifiers), hotkey: changed), .consumed)
    }

    func testDoubleShiftRemainsDefaultAndChangeResetsSequence() {
        var detector = ConversionHotkeyDetector()
        let first = RawKeyEvent(type: .flagsChanged, keyCode: 56, characters: "",
                                modifierFlags: CGEventFlags.maskShift.rawValue, isSynthetic: false, timestamp: 1)
        let second = RawKeyEvent(type: .flagsChanged, keyCode: 60, characters: "",
                                 modifierFlags: CGEventFlags.maskShift.rawValue, isSynthetic: false, timestamp: 100)
        XCTAssertEqual(detector.handle(first, hotkey: .doubleShift), .none)
        XCTAssertEqual(detector.handle(second, hotkey: .doubleShift), .trigger)
        _ = detector.handle(first, hotkey: .doubleShift)
        _ = detector.handle(event(.keyUp), hotkey: custom)
        XCTAssertEqual(detector.handle(second, hotkey: .doubleShift), .none)
    }

    func testPersistenceFallbackAndNormalization() throws {
        let name = "LSwitch.HotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.conversionHotkey, .doubleShift)
        settings.conversionHotkey = custom
        XCTAssertEqual(SettingsStore(defaults: defaults).conversionHotkey, custom)
        settings.conversionHotkey = .init(keyCode: 40, modifiers: 0)
        XCTAssertEqual(settings.conversionHotkey, .doubleShift)
        defaults.set(Data([1, 2, 3]), forKey: "settings.conversionHotkey")
        XCTAssertEqual(SettingsStore(defaults: defaults).conversionHotkey, .doubleShift)
    }

    @MainActor
    func testRegistrationFailureKeepsOldShortcutAndOffReleasesIt() throws {
        let name = "LSwitch.HotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        var allowed = true
        var releases = 0
        let controller = HotkeySettingsController(settings: settings, register: { _ in
            allowed ? { releases += 1 } : nil
        })
        controller.setActive(true)
        XCTAssertTrue(controller.apply(custom))
        allowed = false
        XCTAssertFalse(controller.apply(.init(keyCode: 0, modifiers: custom.modifiers)))
        XCTAssertEqual(settings.conversionHotkey, custom)
        XCTAssertEqual(releases, 0)
        XCTAssertNotNil(controller.message)
        controller.setActive(false)
        XCTAssertEqual(releases, 1)
        controller.setActive(true)
        XCTAssertEqual(settings.conversionHotkey, .doubleShift)
        XCTAssertNotNil(controller.message)
    }

    @MainActor
    func testInactiveApplyChecksRegistrationWithoutHoldingIt() throws {
        let name = "LSwitch.HotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var registrations = 0
        var releases = 0
        let controller = HotkeySettingsController(settings: SettingsStore(defaults: defaults), register: { _ in
            registrations += 1
            return { releases += 1 }
        })
        XCTAssertTrue(controller.apply(custom))
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(releases, 1)
        controller.setActive(true)
        XCTAssertEqual(registrations, 2)
        XCTAssertTrue(controller.apply(.doubleShift))
        XCTAssertEqual(releases, 2)
    }

    private func event(_ type: RawKeyEventType, flags: UInt64? = nil,
                       characters: String = "k", synthetic: Bool = false) -> RawKeyEvent {
        .init(type: type, keyCode: 40, characters: characters, modifierFlags: flags ?? custom.modifiers,
              isSynthetic: synthetic, timestamp: 100)
    }
}
