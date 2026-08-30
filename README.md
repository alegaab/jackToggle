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
quitting the app restores the button automatically, since the grab lasts only as long
as the process does.

The one cost is an **Input Monitoring** permission grant.

## Other hardware

Transport `Audio` is what makes that match safe to seize blind. It excludes the
internal keyboard, and it excludes every USB keyboard — those publish their media
keys on the *same* Consumer page, so the usage pair alone is nowhere near enough.
A USB-C dongle or USB headset is excluded too, though: its buttons arrive over
Transport `USB`.

Widening the match to all Consumer Controls would pick those up, and would pick up
any attached keyboard with them. That is not a symmetric mistake. A seize is
exclusive, so a wrong match doesn't degrade the feature — it silently kills an
unrelated device's media keys for as long as the app runs. A missed match just says
"No headset connected", which is visible and diagnosable with the probe.

So the widening isn't automatic. When something other than the built-in jack is
attached, the menu grows a **Button source** submenu listing every other Consumer
Control device by name, and seizes only the one that's picked. The choice is stored as VID/PID and handed back
to IOKit as a matching dictionary rather than resolved to a device here, so
replugging re-seizes on its own exactly as the automatic path does.

The usage keys stay in that dictionary. One VID/PID spans several HID devices — the
internal keyboard is six — and only the Consumer Control one should ever be seized;
matching on identity alone would take the device's real keys with it.

## Build and run

```bash
./build.sh --install
```

Builds into `build/`, then replaces `/Applications/JackToggle.app` and relaunches.
Drop `--install` to build without touching `/Applications`. Only the Command Line
Tools are needed; Xcode is not.

## First run

1. Click the plug icon in the menu bar → **Button enabled**.
2. The first toggle fails with a permission prompt — that's expected. Click
   **Open System Settings** and enable JackToggle under
   *Privacy & Security › Input Monitoring*.
3. Toggle again. The icon gains a slash, and the menu shows "Blocked a press Ns ago"
   each time you press the inline button. That counter is the proof it's intercepting.

**After every rebuild:** the binary is ad-hoc signed, so a rebuild changes its signature
and macOS drops the Input Monitoring grant. The app notices and quietly switches itself
off rather than failing. To restore it, remove JackToggle from the Input Monitoring list
with **−**, then add it back.

## Icon

The glyph is drawn in `PlugIcon.swift` rather than taken from SF Symbols, because macOS
already uses `headphones` in Control Center and the volume menu — a second one in the
menu bar reads as a system control. The menu bar image and the `.icns` come from the
same geometry, so they can't drift; `build.sh` regenerates the iconset on every build.

## Layout

- `Sources/HeadsetHID.swift` — device matching, target selection, seizing, permissions
- `Sources/PlugIcon.swift` — the plug glyph, menu bar image and app icon
- `Sources/AppDelegate.swift` — status item, menu, state persistence
- `Tools/GenerateIcon.swift` — writes the `.iconset` for `iconutil`
- `Tools/HIDProbe.swift` — diagnostic, see below
- `build.sh` — compiles, assembles and ad-hoc signs the `.app`

## Diagnostics

`Tools/HIDProbe.swift` lists every attached HID device with the properties the app
matches on. It's where the design came from — it's what showed that the inline button
is its own device rather than part of the keyboard.

```bash
swiftc -swift-version 5 JackToggle/Tools/HIDProbe.swift -o /tmp/hidprobe && /tmp/hidprobe
```

Run it first when the grab stops working on unfamiliar hardware (other headsets, a
USB-C dongle, another Mac): the row for the connected device shows why the matching
dictionary isn't catching it.

Its first line also reports what `IOHIDManagerOpen` returned, which doubles as an
outside check on the app:

| | |
|---|---|
| `kIOReturnSuccess` | Input Monitoring granted |
| `kIOReturnNotPermitted` | grant Input Monitoring |
| `kIOReturnExclusiveAccess` | something already holds a seize — JackToggle is blocking |

## History

A `CGEventTap` fallback (`MediaKeyTap.swift`) shipped in the first version, in case
seizing didn't suppress the button. It does suppress it on the CS42L84, so the fallback
was removed in favour of one code path — it was also the blunter mechanism, since
media-key events don't identify their source and filtering them took the keyboard's
own play/next/previous keys with them. See commit `761d448` if it's ever needed for
different hardware, though **Button source** above is the better answer for a
device the automatic match doesn't reach.
