import Foundation
import IOKit.hid

/// Talks to the 3.5mm jack's inline-remote button, which macOS exposes as its own
/// HID device (Consumer Control, Transport "Audio") separate from the keyboard.
///
/// Blocking works by opening that device with `kIOHIDOptionsTypeSeizeDevice`, which
/// routes its input exclusively to us. The system stops seeing the button presses.
/// Audio playback is untouched — that goes through CoreAudio, not this device.
final class HeadsetHID {

    /// Which device the grab points at.
    ///
    /// `.automatic` is the whole app on a Mac with a built-in jack. `.manual` exists
    /// for hardware that puts its buttons behind a different transport — a USB-C
    /// dongle, a USB headset — where no property short of the device's own identity
    /// separates it from a keyboard. Picking one is left to the user rather than
    /// guessed, because a seize is exclusive: the wrong guess silently kills an
    /// unrelated device's media keys for as long as the app runs.
    enum Target: Equatable {
        case automatic
        case manual(vendorID: Int, productID: Int)
    }

    /// A device the grab can be pointed at by name.
    struct Device: Equatable {
        let vendorID: Int
        let productID: Int
        let name: String
        let transport: String

        var target: Target { .manual(vendorID: vendorID, productID: productID) }

        /// Fails for devices that publish no VID/PID — which includes the built-in
        /// jack itself, since it isn't on a bus that has them. Nothing is lost:
        /// those are exactly the devices `.automatic` already covers, and a device
        /// with no identity couldn't be named in a matching dictionary anyway.
        init?(_ device: IOHIDDevice) {
            guard let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
                  let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            else { return nil }
            self.vendorID = vendorID
            self.productID = productID
            self.name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
                ?? String(format: "Unnamed (%04X:%04X)", vendorID, productID)
            self.transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
                ?? "unknown"
        }
    }

    /// The inline button's usage. Note this is also where every third-party keyboard
    /// puts its media keys, so on its own it is far too wide to seize — see
    /// `matching(for:)` for what narrows it.
    private static let consumerControl: [String: Any] = [
        kIOHIDPrimaryUsagePageKey: 0x0C, // Consumer
        kIOHIDPrimaryUsageKey: 0x01,     // Consumer Control
    ]

    private static func matching(for target: Target) -> [String: Any] {
        var dictionary = consumerControl
        switch target {
        case .automatic:
            // Transport "Audio" is what makes the automatic path safe: it excludes
            // the internal keyboard (which reports over SPI on usage pages 1 and
            // 0xFF00) and every USB keyboard, which shares the Consumer page above.
            dictionary[kIOHIDTransportKey] = "Audio"
        case .manual(let vendorID, let productID):
            // The usage keys stay: one VID/PID publishes several HID devices, and
            // only the Consumer Control one should be seized. Matching the identity
            // alone would take the device's actual key collection with it.
            dictionary[kIOHIDVendorIDKey] = vendorID
            dictionary[kIOHIDProductIDKey] = productID
        }
        return dictionary
    }

    enum BlockError: Error {
        case notPermitted
        case ioKit(IOReturn)

        var message: String {
            switch self {
            case .notPermitted:
                return "Input Monitoring permission denied."
            case .ioKit(let r):
                return String(format: "IOKit refused the grab (0x%08X).", UInt32(bitPattern: r))
            }
        }
    }

    /// Fires on every button press we intercept. Used purely for UI feedback so the
    /// user can confirm the grab is live.
    var onButton: ((_ usage: UInt32, _ value: Int) -> Void)?

    private(set) var target: Target = .automatic
    private var seized: IOHIDManager?

    // MARK: - Presence

    /// Enumerating devices needs no permission and no open, so this stays cheap
    /// enough to poll for menu state.
    private static func devices(matching dictionary: [String: Any]) -> Set<IOHIDDevice> {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, dictionary as CFDictionary)
        return IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> ?? []
    }

    /// Whether the device the grab is pointed at is plugged in right now.
    func isTargetConnected() -> Bool {
        let matched = !Self.devices(matching: Self.matching(for: target)).isEmpty
        switch target {
        case .automatic:
            // HID presence only says the machine has a jack — the codec publishes
            // the device with nothing in it. CoreAudio answers the rest.
            return matched && JackPresence.headphonesPlugged
        case .manual:
            // A USB device's HID node really does come and go with the hardware,
            // so here presence means what it says.
            return matched
        }
    }

    /// Everything the grab could be pointed at manually, for the menu to offer when
    /// the automatic match comes up empty.
    func candidates() -> [Device] {
        Self.devices(matching: Self.consumerControl)
            .compactMap(Device.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    /// Re-points the grab, carrying a live one across so callers never have to
    /// sequence stop/start themselves. A failure leaves the app not blocking.
    @discardableResult
    func setTarget(_ newTarget: Target) -> Result<Void, BlockError> {
        guard newTarget != target else { return .success(()) }
        let wasBlocking = isBlocking
        stopBlocking()
        target = newTarget
        return wasBlocking ? startBlocking() : .success(())
    }

    func startBlocking() -> Result<Void, BlockError> {
        if seized != nil { return .success(()) }
        guard hasInputMonitoringPermission else { return .failure(.notPermitted) }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDManagerSetDeviceMatching(m, Self.matching(for: target) as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, hidInputValueCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard r == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            if r == kIOReturnNotPermitted { return .failure(.notPermitted) }
            return .failure(.ioKit(r))
        }

        // The manager keeps matching, so unplugging and replugging re-seizes on its
        // own — which is why a manual target is stored as VID/PID and handed back to
        // IOKit, rather than resolved to one device here.
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
