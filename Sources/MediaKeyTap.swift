import AppKit

/// Fallback for the case where seizing the HID device doesn't stop the system from
/// acting on the button. This intercepts the media-key events the jack driver posts
/// and drops them before anything else sees them.
///
/// Blunter than the HID grab: these events carry no reliable indication of which
/// device produced them, so while active it also swallows the keyboard's own
/// play/next/previous keys. That's why it only runs while a headset is plugged in,
/// and why it isn't the default.
final class MediaKeyTap {

    /// Transport-control subtype of NSSystemDefined.
    private static let auxControlSubtype: Int16 = 8

    /// Play/next/prev/fast/rewind only. Volume and mute are left alone so the
    /// keyboard's volume keys keep working.
    private static let swallowedKeys: Set<Int32> = [16, 17, 18, 19, 20]

    /// Consulted per event, so the caller can gate on headset presence.
    var shouldSwallow: () -> Bool = { false }
    var onKey: ((Int32) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() -> Bool {
        if tap != nil { return true }
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14), // NSSystemDefined
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = s
        return true
    }

    func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }

    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event),
              ns.type == .systemDefined,
              ns.subtype.rawValue == Self.auxControlSubtype else { return false }
        let keyCode = Int32((ns.data1 & 0xFFFF_0000) >> 16)
        guard Self.swallowedKeys.contains(keyCode) else { return false }
        onKey?(keyCode)
        return shouldSwallow()
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables a tap that runs long or when the user changes input state.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reenable()
        return Unmanaged.passUnretained(event)
    }
    return me.handle(event) ? nil : Unmanaged.passUnretained(event)
}
