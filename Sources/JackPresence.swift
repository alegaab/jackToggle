import CoreAudio
import Foundation

/// Whether something is actually plugged into the built-in 3.5mm jack.
///
/// HID can't answer this. The codec publishes the jack's HID device unconditionally,
/// so it is in the device list with the jack empty — presence there means the machine
/// *has* a jack, not that anything is in it. CoreAudio does know: the built-in output
/// device carries a data source that switches away from the internal speakers on
/// insert.
enum JackPresence {

    /// The built-in output's data source with nothing plugged in. Measured, not
    /// assumed: with the jack empty this Mac offers exactly one output source,
    /// `ispk` / "MacBook Pro Speakers".
    private static let internalSpeakers: UInt32 = 0x6973706B // 'ispk'

    /// False on a Mac with no built-in analog output at all, which is the right
    /// answer there too.
    static var headphonesPlugged: Bool {
        guard let device = builtInOutputDevice(), let source = dataSource(of: device) else {
            return false
        }
        // A negation on purpose. `ispk` is the value observable with the jack empty,
        // so it can be verified without hardware in the port; the headphone id never
        // appears until something is plugged in, and testing for it would mean
        // hardcoding a constant this machine never reports. The source list is
        // dynamic — with the jack empty `ispk` is the only one offered.
        return source != internalSpeakers
    }

    /// What the check is actually reading. Printed by `Tools/HIDProbe.swift`, so
    /// the signal can be seen directly rather than inferred from the menu.
    static var diagnostic: String {
        guard let device = builtInOutputDevice(), let source = dataSource(of: device) else {
            return "no built-in analog output"
        }
        let bytes = [UInt8((source >> 24) & 0xFF), UInt8((source >> 16) & 0xFF),
                     UInt8((source >> 8) & 0xFF), UInt8(source & 0xFF)]
        let code = String(bytes: bytes, encoding: .ascii) ?? "????"
        return "output data source '\(code)' — jack \(source != internalSpeakers ? "occupied" : "empty")"
    }

    // MARK: - CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ device: AudioObjectID,
                                 _ address: AudioObjectPropertyAddress,
                                 default fallback: T) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        var out = fallback
        let status = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? out : nil
    }

    private static func dataSource(of device: AudioObjectID) -> UInt32? {
        value(device, address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput),
              default: UInt32(0))
    }

    private static func builtInOutputDevice() -> AudioObjectID? {
        var listAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr, size > 0
        else { return nil }

        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &devices) == noErr
        else { return nil }

        return devices.first {
            // The built-in microphone shares this transport, so requiring an output
            // data source is what separates the two.
            value($0, address(kAudioDevicePropertyTransportType), default: UInt32(0))
                == kAudioDeviceTransportTypeBuiltIn && dataSource(of: $0) != nil
        }
    }
}
