import AudioToolbox
import Foundation

/// Граница C API: unit-тесты не создают звуковые ресурсы и не воспроизводят звук.
struct SystemSoundServices {
    struct PropertyValue {
        let status: OSStatus
        let value: UInt32
        let byteCount: UInt32
    }

    var create: (URL) -> (status: OSStatus, soundID: SystemSoundID)
    var setProperty: (AudioServicesPropertyID, SystemSoundID, UInt32) -> OSStatus
    var getProperty: (AudioServicesPropertyID, SystemSoundID) -> PropertyValue
    var play: (SystemSoundID, @escaping @Sendable () -> Void) -> Void
    var dispose: (SystemSoundID) -> OSStatus

    static var live: SystemSoundServices {
        SystemSoundServices(
            create: { url in
                var soundID: SystemSoundID = 0
                let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
                return (status, soundID)
            },
            setProperty: { property, soundID, value in
                var specifier = soundID
                var value = value
                return AudioServicesSetProperty(
                    property, UInt32(MemoryLayout<SystemSoundID>.size), &specifier,
                    UInt32(MemoryLayout<UInt32>.size), &value
                )
            },
            getProperty: { property, soundID in
                var specifier = soundID
                var value: UInt32 = 0
                var byteCount = UInt32(MemoryLayout<UInt32>.size)
                let status = AudioServicesGetProperty(
                    property, UInt32(MemoryLayout<SystemSoundID>.size), &specifier, &byteCount, &value
                )
                return PropertyValue(status: status, value: value, byteCount: byteCount)
            },
            play: { AudioServicesPlaySystemSoundWithCompletion($0, $1) },
            dispose: { AudioServicesDisposeSystemSoundID($0) }
        )
    }
}
