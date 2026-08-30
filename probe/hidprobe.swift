import Foundation
import IOKit.hid

func prop(_ d: IOHIDDevice, _ k: String) -> String {
    guard let v = IOHIDDeviceGetProperty(d, k as CFString) else { return "-" }
    return String(describing: v)
}
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, nil)
let rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen -> 0x" + String(rc, radix: 16) + "\n")

guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
    print("no devices"); exit(1)
}
let devs = Array(set)
print(pad("PRODUCT", 32) + pad("VID", 8) + pad("PID", 8) + pad("UPAGE", 7) + pad("USAGE", 7) + pad("TRANSPORT", 10))
print(String(repeating: "-", count: 78))
for d in devs.sorted(by: { prop($0, kIOHIDProductKey) < prop($1, kIOHIDProductKey) }) {
    let p = prop(d, kIOHIDProductKey)
    let t = prop(d, kIOHIDTransportKey)
    var line = pad(p, 32) + pad(prop(d, kIOHIDVendorIDKey), 8) + pad(prop(d, kIOHIDProductIDKey), 8)
        + pad(prop(d, kIOHIDPrimaryUsagePageKey), 7) + pad(prop(d, kIOHIDPrimaryUsageKey), 7) + pad(t, 10)
    if t == "Audio" || p.lowercased().contains("head") { line += "  <<< HEADSET" }
    print(line)
}
