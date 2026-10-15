import AudioToolbox
import Foundation
@testable import LSwitchCore
import XCTest

private final class SoundServicesRecorder {
    struct PropertyCall: Equatable {
        let property: AudioServicesPropertyID
        let soundID: SystemSoundID
        let value: UInt32?
    }

    var createStatus: OSStatus = kAudioServicesNoError
    var createdID: SystemSoundID = 41
    var setStatus: OSStatus = kAudioServicesNoError
    var readback = SystemSoundServices.PropertyValue(status: kAudioServicesNoError, value: 0, byteCount: 4)
    private let lock = NSLock()
    private var storedEvents: [(name: String, onMain: Bool)] = []
    private var storedProperties: [PropertyCall] = []
    private var storedDisposed: [SystemSoundID] = []
    private var storedPlayed: [SystemSoundID] = []

    var events: [(name: String, onMain: Bool)] { locked { storedEvents } }
    var properties: [PropertyCall] { locked { storedProperties } }
    var disposed: [SystemSoundID] { locked { storedDisposed } }
    var played: [SystemSoundID] { locked { storedPlayed } }

    var adapter: SystemSoundServices {
        SystemSoundServices(
            create: { _ in
                self.record("create")
                return (self.createStatus, self.createdID)
            },
            setProperty: { property, soundID, value in
                self.record("set")
                self.locked { self.storedProperties.append(.init(property: property, soundID: soundID, value: value)) }
                return self.setStatus
            },
            getProperty: { property, soundID in
                self.record("get")
                self.locked { self.storedProperties.append(.init(property: property, soundID: soundID, value: nil)) }
                return self.readback
            },
            play: { soundID, completion in
                self.record("play")
                self.locked { self.storedPlayed.append(soundID) }
                completion()
            },
            dispose: { soundID in
                self.record("dispose")
                self.locked { self.storedDisposed.append(soundID) }
                return kAudioServicesNoError
            }
        )
    }

    private func record(_ name: String) {
        locked { storedEvents.append((name, Thread.isMainThread)) }
    }

    @discardableResult
    private func locked<Value>(_ action: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }
}

final class SystemSoundFeedbackBackendTests: XCTestCase {
    func testPrepareChangesOnlyOwnedSoundPropertyAndNeverPlays() {
        let recorder = SoundServicesRecorder()
        let backend = SystemSoundFeedbackBackend(services: recorder.adapter)
        XCTAssertTrue(backend.prepare())
        XCTAssertTrue(backend.prepare())
        XCTAssertEqual(recorder.events.map(\.name), ["create", "set", "get"])
        XCTAssertEqual(recorder.properties, [
            .init(property: kAudioServicesPropertyIsUISound, soundID: 41, value: 0),
            .init(property: kAudioServicesPropertyIsUISound, soundID: 41, value: nil)
        ])
        XCTAssertTrue(recorder.played.isEmpty)
        backend.dispose()
        backend.dispose()
        XCTAssertEqual(recorder.disposed, [41])
    }

    func testSetFailureDisposesUnusableIDAndNeverPlays() {
        let recorder = SoundServicesRecorder()
        recorder.setStatus = -50
        let backend = SystemSoundFeedbackBackend(services: recorder.adapter)
        XCTAssertFalse(backend.prepare())
        let finished = expectation(description: "отклонённая попытка завершается без play API")
        backend.play { finished.fulfill() }
        wait(for: [finished], timeout: 1)
        backend.dispose()
        XCTAssertEqual(recorder.events.map(\.name), ["create", "set", "dispose"])
        XCTAssertEqual(recorder.disposed, [41])
        XCTAssertTrue(recorder.played.isEmpty)
    }

    func testReadbackErrorWrongValueAndWrongSizeAllFailClosed() {
        let invalidValues = [
            SystemSoundServices.PropertyValue(status: -50, value: 0, byteCount: 4),
            SystemSoundServices.PropertyValue(status: kAudioServicesNoError, value: 1, byteCount: 4),
            SystemSoundServices.PropertyValue(status: kAudioServicesNoError, value: 0, byteCount: 1)
        ]
        for invalidValue in invalidValues {
            let recorder = SoundServicesRecorder()
            recorder.readback = invalidValue
            let backend = SystemSoundFeedbackBackend(services: recorder.adapter)
            XCTAssertFalse(backend.prepare())
            XCTAssertEqual(recorder.events.map(\.name), ["create", "set", "get", "dispose"])
            XCTAssertEqual(recorder.disposed, [41])
            XCTAssertTrue(recorder.played.isEmpty)
        }
    }

    func testCreationFailureDoesNotConfigureOrDisposeAnUnownedID() {
        let failures: [(OSStatus, SystemSoundID)] = [(-50, 0), (kAudioServicesNoError, 0)]
        for (status, soundID) in failures {
            let recorder = SoundServicesRecorder()
            recorder.createStatus = status
            recorder.createdID = soundID
            let backend = SystemSoundFeedbackBackend(services: recorder.adapter)
            XCTAssertFalse(backend.prepare())
            backend.dispose()
            XCTAssertEqual(recorder.events.map(\.name), ["create"])
            XCTAssertTrue(recorder.properties.isEmpty)
        }
    }

    func testFailedConfigurationCanRetryWithANewOwnedID() {
        let recorder = SoundServicesRecorder()
        recorder.setStatus = -50
        let backend = SystemSoundFeedbackBackend(services: recorder.adapter)
        XCTAssertFalse(backend.prepare())
        recorder.setStatus = kAudioServicesNoError
        recorder.createdID = 42
        XCTAssertTrue(backend.prepare())
        let finished = expectation(description: "подменённый play завершается")
        backend.play { finished.fulfill() }
        wait(for: [finished], timeout: 1)
        backend.dispose()
        XCTAssertEqual(recorder.played, [42])
        XCTAssertEqual(recorder.disposed, [41, 42])
    }

    @MainActor
    func testPropertyConfigurationAndPlaybackRemainOffMain() async {
        let recorder = SoundServicesRecorder()
        let controller = SoundFeedbackController(backendFactory: {
            SystemSoundFeedbackBackend(services: recorder.adapter)
        })
        controller.setEnabled(true)
        await controller.drainScheduledWork()
        controller.conversionSucceeded()
        await controller.drainScheduledWork()
        controller.shutdown()
        await controller.drainScheduledWork()
        XCTAssertEqual(recorder.events.map(\.name), ["create", "set", "get", "play", "dispose"])
        XCTAssertFalse(recorder.events.contains { $0.onMain })
        XCTAssertEqual(recorder.played, [41])
    }
}
