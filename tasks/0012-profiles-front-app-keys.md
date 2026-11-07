---
id: "0012"
title: Per-app profiles model, front-app reporting, key shortcuts on the Mac
status: doing
milestone: M2
depends: []
---

## Goal

The Mac tells the iPad which app is in front, the iPad resolves the matching
profile from its settings, and a `Gesture.key` message presses real keys
(with real modifier press/release) in the frontmost Mac app.

## Context

Read `docs/decisions/0006-app-profiles-and-shortcuts.md` first; it is the spec.

- Protocol: `Packages/NibCore/Sources/NibCore/Transport/ControlMessage.swift`
  (add `frontApp(FrontApp)` with `bundleID`, `name`) and `Transport/Gesture.swift`
  (add `key(KeyChord, action)`; `KeyChord` = `keyCode: UInt16` +
  `modifiers: Set` or option set of command/option/control/shift; action
  `tap|down|up`). Codable shape stays `{"type": ...}` like the existing cases.
- Mac injection: `GestureEventBuilder.swift` already presses/releases the zoom
  modifier with `flagsChanged` and tracks `heldModifier` (see its tests in
  `GestureEventBuilderTests.swift`). Extend the same approach: `tap` =
  modifiers down (flagsChanged, cumulative flags) → key down/up → modifiers up
  in reverse; `down`/`up` hold the chord; track held chords and release all in
  `releaseHeldModifier()` (rename to `releaseAll()` if clearer).
  `PenInjectionController.sessionEnded()` already calls it.
  Reuse the builder for undo/redo instead of duplicating.
- Mac front app: in `Apps/NibMac/NibMacApp.swift`, observe
  `NSWorkspace.shared.notificationCenter` `didActivateApplicationNotification`;
  ignore NibMac itself. `PenLinkReceiver` (`Transport/PenLink.swift`) needs a
  public `sendControl`-style API to send `frontApp` to the current session
  (TCP on Wi-Fi, 0x01 frame on USB — both paths exist privately). Send the
  current front app right after a session is accepted.
- iPad side: `PenLinkSender` and `UsbLinkListener` must surface received
  `frontApp` (callback), `NetworkSink` in `Apps/NibPad/NibPadApp.swift`
  stores `frontApp` and exposes the active profile.
- Settings: `Settings/PadSettings.swift`. Add `profiles: [Profile]` where
  `Profile` = `id: UUID`, `name`, `bundleIDPrefixes: [String]`,
  `buttons: [ShortcutButton]` (`label`, `chord`, `hold: Bool`),
  `strip: Strip` (`mode`: scroll | zoom | brushSize | off; `side`: left |
  right), `gestures: Gestures` (move the existing per-pad gesture options
  into each profile; zoom modifier differs per app). The first profile is
  Default and matches nothing. `func profile(forBundleID:) -> Profile`.
  Decoding old saved settings (no `profiles` key) must not lose pressure
  settings: use `decodeIfPresent` with presets as fallback.
- Presets (keep short, editable later): Default (Undo ⌘Z, Redo ⇧⌘Z, Brush
  `B`, Eraser `E`, Pan Space hold, `[` `]`), Krita (`org.kde.krita`; zoom
  modifier control; B, E, Space hold, Ctrl hold for color pick, ⌘Z, ⇧⌘Z),
  Photoshop (`com.adobe.Photoshop`; zoom option; B, E, Space hold, ⌥ hold,
  ⌘Z, ⇧⌘Z), Affinity (`com.seriflabs.`; zoom command; B, E, Space hold, ⌘Z,
  ⇧⌘Z). Use virtual key codes from HIToolbox Events.h (Z=6, B=11, E=14,
  Space=49, `[`=33, `]`=30).
- Gesture options must still travel with each gesture (Mac stays stateless):
  `FingerGestureController` reads options from the active profile instead of
  `PadSettings.gestures`.

## Acceptance

- [ ] `ControlMessage.frontApp` and `Gesture.key` round-trip through
  `ControlFramer` and `StreamFramer` (tests).
- [ ] `GestureEventBuilder` tests: `tap` of ⇧⌘Z emits flagsChanged(⌘),
  flagsChanged(⌘⇧), keyDown, keyUp, flagsChanged(⌘), flagsChanged([]);
  `down` Space then `releaseAll()` emits Space keyUp; a held ⌥ chord is
  released on session end; undo/redo still produce the same sequences.
- [ ] `PadSettings` tests: old JSON without `profiles` decodes with pressure
  intact and the four presets; `profile(forBundleID: "org.kde.krita")` is
  Krita, `"com.seriflabs.affinityphoto2"` is Affinity, unknown → Default.
- [ ] NibMac sends `frontApp` on accept and on activation change (code
  path reviewed; manual check below).
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Any iPad UI for buttons, strip or editing profiles (0013, 0014). The
  companion panel only needs to keep compiling; showing "Profile: <name>"
  next to the link state is welcome.
- Changing pen/tablet event code or the transport handshake.

## Handoff

```
Branch/commit: t3/fix-gesture-modifier-handling @ f3f6402
Verify: verify: ok (Test run with 79 tests; NibMac + NibPad built)
Done:
- Added Codable front-app and key gesture protocol messages over TCP and USB.
- Added stateful modifier/key injection with releaseAll safety and reused it for undo/redo.
- Added migrated per-app profiles and active-profile gesture selection on iPad.
- Added Mac front-app reporting on session acceptance and activation changes.
- Added modifier-only chords for Krita Pick and Photoshop Alt, preserving held modifiers across taps.
- Kept shortcut holds through pen contact and added session-end cleanup and regression coverage.
Manual checks: switch between Krita and Finder with the iPad connected; the
  iPad panel shows the matching profile name. (not run; needs real iPad)
Not done / risks:
```
