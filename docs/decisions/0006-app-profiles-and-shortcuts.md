# 0006 — Per-app profiles owned by the iPad, keys as gestures

Date: 2026-11-07 · Status: accepted

## Context

The user wants Wacom-style ExpressKeys (on-screen shortcut buttons) and a
scroll/zoom strip on the iPad, switching automatically with the frontmost
Mac app (Krita, Photoshop, Affinity), and edited on the iPad, not the Mac.
Krita showed that a modifier sent only as an event flag is never seen as
released (Qt tracks `flagsChanged`), leaving the app in modifier mode.

## Decision

- **Mac reports, iPad decides.** NibMac watches the frontmost application
  (`NSWorkspace.didActivateApplicationNotification`) and sends a new control
  message `frontApp { bundleID, name }` on session start and on change. It
  holds no profile state.
- **Profiles live on the iPad** (`PadSettings`, persisted with the rest):
  a profile has a name, matching bundle IDs, shortcut buttons, strip
  configuration and gesture options. The active profile is the first whose
  bundle IDs contain the front app, else the Default profile. Presets ship
  for Krita (`org.kde.krita`), Photoshop (`com.adobe.Photoshop`) and
  Affinity (bundle IDs starting `com.seriflabs.`).
- **Keys travel as a gesture**: `Gesture.key(KeyChord, action)` where
  `KeyChord` = macOS virtual key code + modifier set (command, option,
  control, shift) and `action` ∈ `tap`, `down`, `up`. `down`/`up` support
  hold buttons (Space to pan, a held modifier). The Mac injects modifiers
  with real `flagsChanged` press/release events around the key.
- **Release guarantees on the Mac**: a key held by `down` is released by
  the matching `up`, and every held key and modifier is released on session
  end. The iPad sends `up` when a hold button's touch ends or is cancelled.
- **The strip reuses gestures**: slide → `scroll`, `zoom`, or repeated
  `key` taps per distance step (brush size `[`/`]`). No new Mac logic.

## Consequences

- One protocol addition (`frontApp`, `Gesture.key`); older Macs reject the
  unknown control type, so both apps must be updated together (fine before
  release; `protocolVersion` stays 1).
- Profiles survive Mac reinstalls and move with the iPad; editing keys
  without a hardware keyboard needs a key picker on the iPad.
- Synthetic key events reach the frontmost app only, which is the intent.
