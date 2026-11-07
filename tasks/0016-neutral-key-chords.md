---
id: "0016"
title: Protocol v2 — platform-neutral key chords and settings migration
status: review
milestone: M3
depends: []
---

## Goal

Key chords and zoom modifiers on the wire and in iPad settings use W3C
`KeyboardEvent.code` names and neutral modifiers (`primary`, `control`,
`alt`, `shift`, `meta`). The Mac maps them to `kVK_*` codes. A user's existing
iPad profiles survive the upgrade.

## Context

- Read `docs/decisions/0008-protocol-v2.md` (keys, modifiers, migration)
  and 0006 (keys as gestures).
- `Gesture.KeyChord` / `Gesture.Modifier` in
  `Packages/NibCore/Sources/NibCore/Transport/Gesture.swift`: replace
  `keyCode: UInt16?` with `key: String?` (a W3C code). Make modifiers
  `primary, control, alt, shift, meta`. Wire JSON:
  `{"key":"KeyZ","modifiers":["primary","shift"]}`.
- Decoding stays backward compatible **for stored settings**: a chord with
  `keyCode` (macOS ANSI `kVK_*`) is converted through a reverse table, and
  `command` → `primary`, `option` → `alt`. `PadSettings.ZoomModifier`
  (`command/option/control`) migrates the same way into the neutral modifier set.
- `Settings/KeyNames.swift` becomes the neutral table: W3C code, display name,
  group, for every key the picker offers today. Add a separate macOS mapping
  (W3C code → `kVK_*`) used only by `GestureEventBuilder` (macOS).
  `displayName(for:)` takes a host platform (`.macos` default) so `primary`
  shows ⌘ on macOS and Ctrl elsewhere. A minimal `HostPlatform` enum
  (`macos, windows, linux`) in NibCore is fine; 0017 will put it on the wire.
- Mac (`GestureEventBuilder.swift`): `primary` and `meta` → command, `alt` →
  option. An unknown key code is skipped with a log line, never a crash, and
  never leaves a modifier pressed.
- Presets in `PadSettings.swift` use `primary` for Undo/Redo and Affinity's
  zoom; Krita's zoom stays `control`, Photoshop's becomes `alt`.
- Apps: `ProfileEditor.swift`, `EdgeControlsView.swift`,
  `FingerGestureController.swift`, `CompanionPanel.swift` follow the new
  types. The picker's modifier toggles read ⌘ Primary / ⌃ Control / ⌥ Alt / ⇧ Shift / Meta.

## Acceptance

- [ ] `Gesture.key` encodes as the JSON above. Test: encode/decode round-trip
  for a chord with key, a modifier-only chord, and all five modifiers.
- [ ] Test: a `PadSettings` JSON blob in the **v1 format** (copy one produced by
  current `main`, with `keyCode` and `command`/`option` chords and a
  `zoomModifier`) decodes into the equivalent v2 settings; re-encoding writes no
  `keyCode`, `command` or `option`.
- [ ] Test: every key in `KeyNames.pickerKeys` has a macOS `kVK_*` mapping,
  and the codes match the values in the old table (no key moved).
- [ ] Test: `GestureEventBuilder` turns `primary+KeyZ` into the same events as
  v1's command+6, and an unknown key (`"Lang9"`) produces no key events and no
  stuck modifiers.
- [ ] `displayName` renders `primary+shift+KeyZ` as `⇧⌘Z` for macOS and
  `Ctrl+Shift+Z` for windows/linux (test).
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Handshake changes, host capabilities, `appID` (task 0017).
- `docs/protocol.md` and vectors (task 0018).
- New keys in the picker.

## Handoff

```
Branch/commit: t3/neutral-key-chords-migration @ 27c23ced4ad4aec5e80b28acc4cf8d35c4ca0e6a
Verify: verify: ok (Test run with 109 tests; NibMac + NibPad built)
Done:
- Replaced keyCode and command/option wire/settings values with W3C codes and neutral modifiers.
- Added lossless v1 chord and zoom modifier decoding with v2-only re-encoding.
- Added neutral picker mappings, platform display names, Mac event translation, unknown-key logging, and updated iPad editors/presets.
- Added migration, mapping, round-trip, display, and event-builder tests.
Manual checks: Real iPad Pencil settings migration and drawing-app shortcuts not run (hardware/manual check).
Not done / risks: Unknown legacy macOS key codes outside the existing picker table cannot be translated to a W3C code and decode as an empty key.
```
