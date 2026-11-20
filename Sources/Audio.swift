import Foundation
import CoreAudio

/// Reads and writes the system output volume / mute state through CoreAudio.
///
/// Verified working on macOS 27 with the built-in "Mac mini扬声器" output device using
/// the `'vmvc'` (virtual main volume) and `'mute'` property selectors.
final class AudioController {

    static let shared = AudioController()

    private let vmvc = AudioController.fourCC("vmvc")
    private let muteSelector = AudioController.fourCC("mute")
    private let defaultOutputSelector = AudioController.fourCC("dOut")
    private let nameSelector = AudioController.fourCC("lnam")

    private init() {}

    private static func fourCC(_ string: String) -> AudioObjectPropertySelector {
        var result: UInt32 = 0
        for byte in string.utf8 { result = (result << 8) + UInt32(byte) }
        return result
    }

    // MARK: - Device

    var defaultOutputDevice: AudioObjectID {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: defaultOutputSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    var outputDeviceName: String {
        let device = defaultOutputDevice
        guard device != 0 else { return "Unknown" }
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: nameSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let result = name as String?, !result.isEmpty else { return "Unknown" }
        return result
    }

    // MARK: - Volume

    private func hasVolume(_ device: AudioObjectID) -> Bool {
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: vmvc,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &address)
    }

    var volume: Double? {
        let device = defaultOutputDevice
        guard hasVolume(device) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: vmvc,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    @discardableResult
    func setVolume(_ value: Double) -> Bool {
        let device = defaultOutputDevice
        guard hasVolume(device) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: vmvc,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var clamped = Float32(min(1.0, max(0.0, value)))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &clamped) == noErr
    }

    func stepVolume(by delta: Double) {
        guard let current = volume else { return }
        setVolume(current + delta)
    }

    // MARK: - Mute

    var isMuted: Bool {
        let device = defaultOutputDevice
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: muteSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        let device = defaultOutputDevice
        guard device != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: muteSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    func toggleMute() {
        setMuted(!isMuted)
    }
}
