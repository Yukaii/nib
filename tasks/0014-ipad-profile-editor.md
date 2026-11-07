---
id: "0014"
title: iPad companion panel — profile editor for buttons, strip and gestures
status: doing
milestone: M2
depends: ["0012"]
---

## Goal

From the four-finger-tap companion panel the user can see the active profile,
pick any profile, and edit its buttons (label, key, modifiers, hold), strip
mode/side and gesture options, without a hardware keyboard.

## Context

Spec: `docs/decisions/0006-app-profiles-and-shortcuts.md`. 0012 added
`PadSettings.profiles`, `Profile`, `KeyChord`, `ShortcutButton`, presets and
`profile(forBundleID:)`; settings persist through `PadSettingsStore`
(`@Observable`, UserDefaults `nib.padSettings`).

- Panel: `Apps/NibPad/CompanionPanel.swift` (SwiftUI, dark). The existing
  Gestures section edits options that now live per profile; move it into the
  profile editor.
- Layout: a "Profiles" section showing "Active: <name> (front app: <app>)",
  a list of profiles; tapping one opens an editor (NavigationStack or sheet).
- Editor: name; app bundle-ID prefixes (text fields, add/remove; offer
  "Use current front app" which fills the front app's bundle ID);
  buttons list (add, delete, reorder, max 8); per button: label, key picker,
  modifier toggles (⌘ ⌥ ⌃ ⇧), Hold toggle; strip mode + side; gesture
  options (scroll, pinch zoom + modifier, tap undo/redo).
- Key picker without a keyboard: a grid of common keys with virtual key codes
  (letters A–Z, digits 0–9, Space, Tab, Esc, Delete, Return, `[`, `]`, `-`,
  `=`, arrows, F1–F12) from a pure NibCore table
  (`Settings/KeyNames.swift`: code → display name, display name for a chord
  like "⇧⌘Z"). If a hardware keyboard is attached, a "Press keys…" capture is
  welcome but optional.
- Default profile can be edited but not deleted or bound to apps. "Reset to
  presets" restores the four presets after confirmation.

## Acceptance

- [ ] `KeyNames` tests: code 6 → "Z", 49 → "Space", 33 → "[", chord
  ⇧⌘Z → "⇧⌘Z" (Apple modifier order ⌃⌥⇧⌘); every code in the picker table
  has a unique name.
- [ ] `PadSettings` tests: deleting a profile keeps Default; editing a
  button persists through encode/decode.
- [ ] Panel builds and shows the active profile; edits persist across app
  relaunch (manual check).
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Drawing the edge controls themselves (0013). Mac-side changes.

## Handoff

```
Branch/commit: t3/ipad-profile-editor @ 67b37b8
Verify: verify: ok (Test run with 88 tests; NibMac + NibPad built)
Done:
- NibCore `KeyNames` (code → name, picker table of 61 keys, chord display in
  ⌃⌥⇧⌘ order; modifier-only chords show just symbols) + tests.
- `PadSettings`: `addProfile`, `deleteProfile` (Default protected),
  `resetProfilesToPresets` (keeps pressure), `Profile.addButton/moveButton`
  (max 8), `isDefault`; removed the `gestures` compatibility accessor.
- `profile(forBundleID:)` now ignores empty prefixes and never matches Default
  (a half-typed prefix would otherwise match every app).
- Panel: Profiles section (active + front app, list, add, reset with
  confirmation) opening `ProfileEditor` (new file) as a sheet: name, app
  prefixes + "Use current front app", buttons (label, key grid with "None
  (modifiers only)", ⌃⌥⇧⌘ toggles, Hold, reorder, delete), strip, gestures.
  Profile deletion lives in the editor.
Manual checks: open panel, edit the Krita profile's button key and label,
  relaunch NibPad, change persists; "Use current front app" fills the
  bundle ID while Krita is front. (needs iPad) — not run.
Not done / risks: Hardware-keyboard "Press keys…" capture skipped (optional).
  `NetworkSink` is not observable, so the front app shown in the panel is
  refreshed when the panel re-renders (open, or any settings edit), not live.
  Editor layout unseen on a device; built only.
```
