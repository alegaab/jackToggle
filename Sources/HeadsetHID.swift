import Foundation
import IOKit.hid

/// Talks to the 3.5mm jack's inline-remote button, which macOS exposes as its own
/// HID device (Consumer Control, Transport "Audio") separate from the keyboard.
///
/// Blocking works by opening that device with `kIOHIDOptionsTypeSeizeDevice`, which
/// routes its input exclusively to us. The system stops seeing the button presses.
/// Audio playback is untouched — that goes through CoreAudio, not this device.
final class HeadsetHID {

    /// Deliberately narrow: Transport "Audio" excludes the internal keyboard, which
    /// reports on usage pages 1 and 0xFF00 over SPI.
    private static let matching: [String: Any] = [
        kIOHIDTransportKey: "Audio",
        kIOHIDPrimaryUsagePageKey: 0x0C, // Consumer
        kIOHIDPrimaryUsageKey: 0x01,     // Consumer Control
    ]

    enum BlockError: Error {
        case notPermitted
        case noDevice
        case ioKit(IOReturn)

        var message: String {
            switch self {
            case .notPermitted:
                return "Input Monitoring permission denied."
            case .noDevice:
                return "No wired headset with buttons is connected."
            case .ioKit(let r):
                return String(format: "IOKit refused the grab (0x%08X).", UInt32(bitPattern: r))
            }
        }
    }

    /// Fires on every button press we intercept. Used purely for UI feedback so the
    /// user can confirm the grab is live.
    var onButton: ((_ usage: UInt32, _ value: Int) -> Void)?

    private var seized: IOHIDManager?

    // MARK: - Presence

    /// Enumerating devices needs no permission and no open, so this stays cheap
    /// enough to poll for menu state.
    func isHeadsetConnected() -> Bool {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, Self.matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return false }
        return !devices.isEmpty
    }

    // MARK: - Permission

    var hasInputMonitoringPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Only prompts once per app signature; afterwards the user must use System Settings.
    @discardableResult
    func requestInputMonitoringPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - Blocking

    var isBlocking: Bool { seized != nil }

    func startBlocking() -> Result<Void, BlockError> {
        if seized != nil { return .success(()) }
        guard hasInputMonitoringPermission else { return .failure(.notPermitted) }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDManagerSetDeviceMatching(m, Self.matching as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, hidInputValueCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard r == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            if r == kIOReturnNotPermitted { return .failure(.notPermitted) }
            return .failure(.ioKit(r))
        }

        // The manager keeps matching, so unplugging and replugging re-seizes on its own.
        seized = m
        return .success(())
    }

    func stopBlocking() {
        guard let m = seized else { return }
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        seized = nil
    }
}

private let hidInputValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else { return }
    let hid = Unmanaged<HeadsetHID>.fromOpaque(context).takeUnretainedValue()
    let element = IOHIDValueGetElement(value)
    hid.onButton?(IOHIDElementGetUsage(element), IOHIDValueGetIntegerValue(value))
}
