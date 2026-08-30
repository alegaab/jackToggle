import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    enum Method: String {
        case hidGrab      // seize the headset HID device — surgical, the default
        case mediaKeyTap  // swallow media-key events — fallback
    }

    private enum Key {
        static let blocking = "blocking"
        static let method = "method"
    }

    private let hid = HeadsetHID()
    private let keyTap = MediaKeyTap()
    private var statusItem: NSStatusItem!

    private var blocking = false
    private var method: Method = .hidGrab
    private var lastPress: Date?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        blocking = defaults.bool(forKey: Key.blocking)
        method = Method(rawValue: defaults.string(forKey: Key.method) ?? "") ?? .hidGrab

        hid.onButton = { [weak self] _, value in
            // Down and up both arrive; only note the press.
            guard value != 0 else { return }
            self?.lastPress = Date()
        }
        keyTap.shouldSwallow = { [weak self] in
            guard let self else { return false }
            return self.blocking && self.method == .mediaKeyTap && self.hid.isHeadsetConnected()
        }
        keyTap.onKey = { [weak self] _ in self?.lastPress = Date() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Restore the saved state, but never nag on launch: if permission is gone,
        // fall back to off rather than throwing an alert at login.
        if blocking, case .failure = applyBlocking(true) {
            blocking = false
            defaults.set(false, forKey: Key.blocking)
        }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        applyBlocking(false)
    }

    // MARK: - Blocking

    @discardableResult
    private func applyBlocking(_ on: Bool) -> Result<Void, HeadsetHID.BlockError> {
        guard on else {
            hid.stopBlocking()
            keyTap.stop()
            return .success(())
        }
        switch method {
        case .hidGrab:
            keyTap.stop()
            return hid.startBlocking()
        case .mediaKeyTap:
            hid.stopBlocking()
            guard keyTap.hasAccessibilityPermission else { return .failure(.notPermitted) }
            return keyTap.start() ? .success(()) : .failure(.notPermitted)
        }
    }

    @objc private func toggleBlocking() {
        let target = !blocking
        if target, case .failure(let error) = applyBlocking(true) {
            presentPermissionAlert(error)
            return
        }
        if !target { applyBlocking(false) }
        blocking = target
        lastPress = nil
        UserDefaults.standard.set(blocking, forKey: Key.blocking)
        updateIcon()
    }

    @objc private func selectMethod(_ sender: NSMenuItem) {
        guard let new = Method(rawValue: sender.representedObject as? String ?? ""),
              new != method else { return }
        let wasBlocking = blocking
        applyBlocking(false)
        method = new
        UserDefaults.standard.set(new.rawValue, forKey: Key.method)
        if wasBlocking, case .failure(let error) = applyBlocking(true) {
            blocking = false
            UserDefaults.standard.set(false, forKey: Key.blocking)
            presentPermissionAlert(error)
        }
        updateIcon()
    }

    // MARK: - Permissions

    private func presentPermissionAlert(_ error: HeadsetHID.BlockError) {
        let needsInputMonitoring = method == .hidGrab

        if needsInputMonitoring {
            hid.requestInputMonitoringPermission()
        } else {
            keyTap.requestAccessibilityPermission()
        }

        let pane = needsInputMonitoring ? "ListenEvent" : "Accessibility"
        let name = needsInputMonitoring ? "Input Monitoring" : "Accessibility"

        let alert = NSAlert()
        alert.messageText = "JackToggle needs \(name) access"
        alert.informativeText = """
        \(error.message)

        Enable JackToggle under Privacy & Security › \(name), then toggle again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = blocking ? "headphones.slash" : "headphones"
        let label = blocking ? "Headset buttons disabled" : "Headset buttons enabled"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.image?.isTemplate = true
        button.toolTip = "JackToggle — \(label)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let connected = hid.isHeadsetConnected()
        menu.addItem(header(connected ? "Headset connected" : "No headset connected"))

        let toggle = NSMenuItem(title: blocking ? "Buttons disabled" : "Buttons enabled",
                                action: #selector(toggleBlocking), keyEquivalent: "")
        toggle.target = self
        toggle.state = blocking ? .on : .off
        menu.addItem(toggle)

        if blocking, let last = lastPress {
            let seconds = Int(Date().timeIntervalSince(last))
            menu.addItem(header(seconds < 2 ? "Blocked a press just now"
                                            : "Blocked a press \(seconds)s ago"))
        } else if blocking && !connected {
            menu.addItem(header("Will apply when a headset is plugged in"))
        }

        menu.addItem(.separator())

        let methodItem = NSMenuItem(title: "Method", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(methodEntry("Grab headset device", .hidGrab))
        submenu.addItem(methodEntry("Filter media keys", .mediaKeyTap))
        methodItem.submenu = submenu
        menu.addItem(methodItem)

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit JackToggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func methodEntry(_ title: String, _ value: Method) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectMethod(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value.rawValue
        item.state = method == value ? .on : .off
        return item
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
}
