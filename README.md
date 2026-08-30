# JackToggle

Menu bar app that turns the 3.5mm headset's inline button on and off.

## Why not `kextunload`

The usual advice is `sudo kextunload -b com.apple.driver.AppleMikeyHIDDriver`.
That does not work on this machine, and can't be made to:

- `kextload`/`kextunload` were deprecated in Catalina and removed; `kmutil` replaced them.
- `AppleMikeyHIDDriver.kext` exists in `/System/Library/Extensions`, but is not what's
  driving the jack. The live driver is `AppleCS42L84Mikey` (the CS42L84 codec), and it
  lives in the **boot kernel collection**.
- Boot-collection drivers on Apple Silicon cannot be unloaded at runtime at all — not
  with SIP disabled either. Removing one means lowering the security policy in
  recoveryOS and rebooting, which is a permanent, machine-wide change.

## What it does instead

macOS exposes the inline button as its own HID device, distinct from the keyboard:

| | Headset button | Internal keyboard |
|---|---|---|
| Transport | `Audio` | `SPI` |
| Usage page | `12` (Consumer) | `1`, `65280` |
| Usage | `1` (Consumer Control) | `2`, `6`, `11`, `13` |

So the app opens **only that device** with `kIOHIDOptionsTypeSeizeDevice`, which routes
its input exclusively to JackToggle. The system stops seeing the presses. Nothing else
is affected — the keyboard's media keys keep working, and audio is untouched (that runs
through CoreAudio, not this device).

No `sudo`, no SIP changes, no reboot, no kernel extensions. It toggles instantly, and
quitting the app restores the button automatically.

The one cost is an **Input Monitoring** permission grant.

## Build and run

```bash
./build.sh && open build/JackToggle.app
```

Only the Command Line Tools are needed; Xcode is not.

## First run

1. Click the headphones icon in the menu bar → **Buttons enabled**.
2. The first toggle fails with a permission prompt — that's expected. Click
   **Open System Settings** and enable JackToggle under
   *Privacy & Security › Input Monitoring*.
3. Toggle again. The icon becomes `headphones.slash`, and the menu shows
   "Blocked a press Ns ago" each time you press the inline button.

## Methods

**Grab headset device** (default) — the seize described above. Surgical.

**Filter media keys** — fallback, in case seizing turns out not to suppress the
button on some hardware. It installs a `CGEventTap` and drops play/next/previous
events. Blunter: those events don't identify their source, so while it's active it
also swallows the keyboard's play/next/previous keys. It only runs while a headset is
plugged in, and it needs Accessibility rather than Input Monitoring. Volume and mute
are never swallowed.

## Layout

- `Sources/HeadsetHID.swift` — device matching, seizing, permission checks
- `Sources/MediaKeyTap.swift` — the event-tap fallback
- `Sources/AppDelegate.swift` — status item, menu, state persistence
- `build.sh` — compiles and assembles the `.app`, ad-hoc signed

Rebuilding changes the binary; if macOS drops the Input Monitoring grant after a
rebuild, remove JackToggle from the list with **−** and re-add it.
