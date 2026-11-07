# 0008 — Protocol v2: neutral keys, host info, forward compatibility

Date: 2026-11-07 · Status: accepted

## Context

Nib will get Windows and Linux hosts in Rust (0010). v1 carries macOS
virtual key codes and `command`/`option` modifiers, identifies apps by
bundle ID, ties the control version to the sample layout version, and closes
the connection on any unknown control message. Profiles live on the iPad
(0006), so they must make sense on every host.

## Decision

- **Versions.** `controlVersion = 2` is the session version checked in
  `hello`; the 40-byte sample layout keeps its own `version = 1` (0002).
  Mismatch → `helloAck { accepted: false, reason }` naming the side to update.
- **Keys** are W3C `KeyboardEvent.code` strings (`KeyZ`, `Digit1`, `Space`,
  `BracketLeft`, `ArrowUp`, `F5`…). A chord is
  `{ "key": "KeyZ"?, "modifiers": [...] }`; no `key` = modifier-only.
  A host ignores (and logs) a key it cannot map.
- **Modifiers**: `primary`, `control`, `alt`, `shift`, `meta`. `primary` is
  ⌘ on macOS and Ctrl elsewhere; `meta` is ⌘ / Windows / Super; `alt` is ⌥.
  Presets use `primary` so one profile works on every host.
- **Settings migration**: stored v1 chords (`keyCode`, `command`, `option`)
  decode into v2 (`command` → `primary`, `option` → `alt`); the iPad never
  loses a user's profiles.
- **Hello** adds `deviceID` (UUID, stable per install). `appVersion` comes
  from the bundle, not a literal.
- **HelloAck** adds `host { platform: macos|windows|linux, name, appVersion,
  capabilities: [String] }`. v2 capabilities: `tilt`, `hover`, `eraser`,
  `keys`, `scroll`, `zoomModifierScroll`, `zoomNative`, `rotateNative`,
  `undoRedo`, `frontApp`. Pressure is not a capability: every host must do it.
  The iPad hides or falls back from options the host lacks.
- **Front app** is `frontApp { appID, name }`: bundle ID on macOS, exe name on
  Windows, app ID / `WM_CLASS` on Linux. Profiles match `appIDPrefixes`
  (migrated from `bundleIDPrefixes`).
- **Forward compatibility.** Unknown control `type`s and unknown JSON fields
  are ignored, not fatal. New capabilities and message types are additive and
  need no version bump; removing or changing a field does.
- **Spec.** `docs/protocol.md` + `protocol/vectors/` (JSON + hex) are the
  normative definition; Swift and Rust tests both run the vectors (task 0018).

## Consequences

- One-time break: v1 and v2 apps refuse each other with a readable reason.
- After 1.0, v2 is frozen except for additive changes (PLAN M4).
- The iPad key picker displays `primary` per host (⌘ or Ctrl).
