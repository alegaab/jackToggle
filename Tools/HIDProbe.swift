import Foundation
import IOKit
import IOKit.hid

// Diagnostic: lists every attached HID device with the properties JackToggle matches on.
//
// This is where the app's design came from. It showed that the jack's inline button is
// its own device — UsagePage 12 (Consumer), Usage 1, Transport "Audio" — separate from
// the keyboard, which is what makes a targeted seize possible. Those three values are
// the matching dictionary in Sources/HeadsetHID.swift.
//
// Reach for it when the grab stops working on unfamiliar hardware (other headsets, a
// USB-C dongle, another Mac): the row for the connected device shows why the matching
// dictionary isn't catching it.
//
//   swiftc -swift-version 5 -framework CoreAudio \
//       JackToggle/Sources/JackPresence.swift JackToggle/Tools/HIDProbe.swift \
//       -o /tmp/hidprobe && /tmp/hidprobe

func prop(_ d: IOHIDDevice, _ k: String) -> String {
    guard let v = IOHIDDeviceGetProperty(d, k as CFString) else { return "-" }
    return String(describing: v)
}
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

@main
enum HIDProbe {
    static func main() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        // Opening needs Input Monitoring, but enumerating below does not — so a refusal here
        // is informational, not fatal.
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let meaning: String
        switch status {
        case kIOReturnSuccess:
            meaning = "Input Monitoring granted"
        case kIOReturnNotPermitted:
            meaning = "not permitted — grant Input Monitoring to open devices"
        case kIOReturnExclusiveAccess:
            // Seizing is exclusive, so this is what a live grab looks like from outside.
            meaning = "a device is already seized — JackToggle is probably blocking"
        default:
            meaning = "unexpected"
        }
        print(String(format: "IOHIDManagerOpen -> 0x%08X (%@)", UInt32(bitPattern: status), meaning))

        // The rows below cannot answer whether the jack is occupied: the codec publishes
        // its HID device either way, so "Headset" is listed with nothing plugged in.
        // This is the signal that can tell, and it is what the app now uses.
        print("built-in jack    -> \(JackPresence.diagnostic)\n")

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            print("no devices"); exit(1)
        }

        print(pad("PRODUCT", 32) + pad("VID", 8) + pad("PID", 8)
            + pad("UPAGE", 7) + pad("USAGE", 7) + pad("TRANSPORT", 10))
        print(String(repeating: "-", count: 78))

        for device in devices.sorted(by: { prop($0, kIOHIDProductKey) < prop($1, kIOHIDProductKey) }) {
            let product = prop(device, kIOHIDProductKey)
            let transport = prop(device, kIOHIDTransportKey)
            var line = pad(product, 32)
                + pad(prop(device, kIOHIDVendorIDKey), 8)
                + pad(prop(device, kIOHIDProductIDKey), 8)
                + pad(prop(device, kIOHIDPrimaryUsagePageKey), 7)
                + pad(prop(device, kIOHIDPrimaryUsageKey), 7)
                + pad(transport, 10)
            if transport == "Audio" || product.lowercased().contains("head") { line += "  <<< HEADSET" }
            print(line)
        }
    }
}
