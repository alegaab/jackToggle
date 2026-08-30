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

- `Sources/HeadsetHID.swift` — device matching, seizing, permission checks
- `Sources/PlugIcon.swift` — the plug glyph, menu bar image and app icon
- `Sources/AppDelegate.swift` — status item, menu, state persistence
- `Tools/GenerateIcon.swift` — writes the `.iconset` for `iconutil`
- `build.sh` — compiles, assembles and ad-hoc signs the `.app`

## History

A `CGEventTap` fallback (`MediaKeyTap.swift`) shipped in the first version, in case
seizing didn't suppress the button. It does suppress it on the CS42L84, so the fallback
was removed in favour of one code path — it was also the blunter mechanism, since
media-key events don't identify their source and filtering them took the keyboard's
own play/next/previous keys with them. See commit `761d448` if it's ever needed for
different hardware; widening the HID matching would be the better fix.
