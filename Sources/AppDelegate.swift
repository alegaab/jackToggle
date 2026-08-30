import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private enum Key {
        static let blocking = "blocking"
        static let vendorID = "deviceVendorID"
        static let productID = "deviceProductID"
    }

    private let hid = HeadsetHID()
    private var statusItem: NSStatusItem!

    private var blocking = false
    private var lastPress: Date?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        blocking = defaults.bool(forKey: Key.blocking)
        defaults.removeObject(forKey: "method") // left over from the removed fallback

        // Restore the chosen device before the grab, so a manual pick survives a
        // relaunch the same way the on/off state does.
        if let vendorID = defaults.object(forKey: Key.vendorID) as? Int,
           let productID = defaults.object(forKey: Key.productID) as? Int {
            hid.setTarget(.manual(vendorID: vendorID, productID: productID))
        }

        hid.onButton = { [weak self] _, value in
            // Press and release both arrive; only note the press.
            guard value != 0 else { return }
            self?.lastPress = Date()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Restore the saved state without nagging: if the permission is gone, fall
        // back to off rather than throwing an alert at login.
        if blocking, case .failure = hid.startBlocking() {
            blocking = false
            defaults.set(false, forKey: Key.blocking)
        }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting always restores the button — the grab lasts only as long as we do.
        hid.stopBlocking()
    }

    // MARK: - Actions

    @objc private func toggleBlocking() {
        if blocking {
            hid.stopBlocking()
        } else if case .failure(let error) = hid.startBlocking() {
            presentPermissionAlert(error)
            return
        }
        blocking.toggle()
        lastPress = nil
        UserDefaults.standard.set(blocking, forKey: Key.blocking)
        updateIcon()
    }

    @objc private func selectAutomaticTarget() {
        select(.automatic)
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? HeadsetHID.Device else { return }
        select(device.target)
    }

    private func select(_ target: HeadsetHID.Target) {
        let defaults = UserDefaults.standard
        if case .manual(let vendorID, let productID) = target {
            defaults.set(vendorID, forKey: Key.vendorID)
            defaults.set(productID, forKey: Key.productID)
        } else {
            defaults.removeObject(forKey: Key.vendorID)
            defaults.removeObject(forKey: Key.productID)
        }

        // Moving a live grab re-opens it, which can fail if the permission went away
        // in between. Drop to off rather than claiming a block that isn't there.
        if case .failure(let error) = hid.setTarget(target) {
            blocking = false
            defaults.set(false, forKey: Key.blocking)
            updateIcon()
            presentPermissionAlert(error)
            return
        }
        lastPress = nil
        updateIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func presentPermissionAlert(_ error: HeadsetHID.BlockError) {
        hid.requestInputMonitoringPermission()

        let alert = NSAlert()
        alert.messageText = "JackToggle needs Input Monitoring access"
        alert.informativeText = """
        \(error.message)

        Enable JackToggle under Privacy & Security › Input Monitoring, then toggle again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let label = blocking ? "Headset button disabled" : "Headset button enabled"
        button.image = PlugIcon.menuBarImage(disabled: blocking)
        button.toolTip = "JackToggle — \(label)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let connected = hid.isTargetConnected()
        menu.addItem(caption(connected ? "Headset connected" : "No headset connected"))

        let toggle = NSMenuItem(title: blocking ? "Button disabled" : "Button enabled",
                                action: #selector(toggleBlocking), keyEquivalent: "")
        toggle.target = self
        toggle.state = blocking ? .on : .off
        menu.addItem(toggle)

        if blocking, let last = lastPress {
            let seconds = Int(Date().timeIntervalSince(last))
            menu.addItem(caption(seconds < 2 ? "Blocked a press just now"
                                             : "Blocked a press \(seconds)s ago"))
        } else if blocking && !connected {
            menu.addItem(caption("Will apply when a headset is plugged in"))
        }

        // Shown whenever there is genuinely a choice to make: something other than
        // the built-in jack is attached, or a manual pick is already active (which
        // keeps the way back to automatic open once that device is unplugged).
        //
        // Deliberately not keyed off `connected`. The codec publishes the built-in
        // jack's HID device whether or not anything is plugged into it, so for
        // `.automatic` that flag is always true and would suppress the picker
        // forever. It only carries information for a manual target.
        let candidates = hid.candidates()
        if hid.target != .automatic || !candidates.isEmpty {
            menu.addItem(.separator())
            menu.addItem(targetMenu(candidates))
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit JackToggle",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func targetMenu(_ candidates: [HeadsetHID.Device]) -> NSMenuItem {
        let submenu = NSMenu()

        let automatic = NSMenuItem(title: "Built-in headset jack",
                                   action: #selector(selectAutomaticTarget), keyEquivalent: "")
        automatic.target = self
        automatic.state = hid.target == .automatic ? .on : .off
        submenu.addItem(automatic)

        if !candidates.isEmpty {
            submenu.addItem(.separator())
            // Worth saying plainly: these are matched by identity, not by transport,
            // so a keyboard can end up in this list and lose its media keys.
            submenu.addItem(caption("Anything picked here loses its media keys"))
            for device in candidates {
                let item = NSMenuItem(title: "\(device.name) (\(device.transport))",
                                      action: #selector(selectTarget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.state = hid.target == device.target ? .on : .off
                submenu.addItem(item)
            }
        }

        let item = NSMenuItem(title: "Button source", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func caption(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }
}
