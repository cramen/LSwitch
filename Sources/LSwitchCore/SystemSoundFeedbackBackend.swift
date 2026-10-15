import AudioToolbox
import Foundation
import os

/// C API System Sound: экземпляр создаётся, используется и освобождается только на sound-worker.
final class SystemSoundFeedbackBackend: SoundFeedbackBackend {
    private let fileURL = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    private let logger = Logger(subsystem: "LSwitch", category: "Sound")
    private let services: SystemSoundServices
    private var soundID: SystemSoundID?

    init(services: SystemSoundServices = .live) { self.services = services }

    func prepare() -> Bool {
        if soundID != nil { return true }
        let (status, created) = services.create(fileURL)
        guard status == kAudioServicesNoError, created != 0 else {
            logger.error("audio.prepare.failed status=\(status, privacy: .public)")
            return false
        }
        guard configureApplicationSound(created) else {
            dispose(created)
            return false
        }
        soundID = created
        return true
    }

    private func configureApplicationSound(_ soundID: SystemSoundID) -> Bool {
        // Свойство относится только к нашему ID. Глобальная галочка UI effects,
        // выбранное устройство, системная громкость и mute остаются без изменений.
        let status = services.setProperty(kAudioServicesPropertyIsUISound, soundID, 0)
        guard status == kAudioServicesNoError else {
            logger.error("audio.ui-policy.set-failed status=\(status, privacy: .public)")
            return false
        }
        let readback = services.getProperty(kAudioServicesPropertyIsUISound, soundID)
        guard readback.status == kAudioServicesNoError,
              readback.byteCount == UInt32(MemoryLayout<UInt32>.size), readback.value == 0 else {
            logger.error("audio.ui-policy.readback-failed status=\(readback.status, privacy: .public)")
            return false
        }
        logger.info("audio.ui-policy.confirmed isUISound=0")
        return true
    }

    func play(completion: @escaping @Sendable () -> Void) {
        guard let soundID else {
            completion()
            return
        }
        // Completion подтверждает завершение попытки, но не слышимый звук и не успешность воспроизведения.
        services.play(soundID, completion)
    }

    func dispose() {
        guard let soundID else { return }
        self.soundID = nil
        dispose(soundID)
    }

    private func dispose(_ soundID: SystemSoundID) {
        let status = services.dispose(soundID)
        logger.info("audio.dispose status=\(status, privacy: .public)")
    }
}
