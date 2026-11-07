---
id: "0010"
title: Finger gestures — two-finger scroll, pinch zoom, tap undo/redo
status: doing
milestone: M2
depends: []
---

## Goal

Fingers on the iPad drive the Mac like a trackpad companion, following
Procreate conventions:
- two-finger drag scrolls (smooth, pixel-precise);
- pinch zooms (modifier + scroll);
- two-finger tap is undo (⌘Z);
- three-finger tap is redo (⇧⌘Z).

The Pencil keeps drawing as before.

## Context

- Options come from `PadSettings.gestures` (NibCore `Settings/PadSettings.swift`,
  already on main). Task 0009 builds the UI and the `PadSettingsStore` in
  parallel. Until it lands, read the defaults (`PadSettings()`), behind a
  tiny protocol or closure that 0009's store can satisfy later.
- Wire: add `ControlMessage.gesture(Gesture)` (NibCore `Transport/`).
  `Gesture` is an enum:
  - `scroll(dx, dy, phase)`, in points of iPad finger travel, with phase
    began/changed/ended/cancelled;
  - `zoom(scaleDelta, phase, modifier)`;
  - `undo`;
  - `redo`.

  It travels on the TCP control channel (reliable, ordered; ≤ 120 Hz is
  fine with `noDelay`). Add round-trip tests. Leave the ping golden test
  unchanged.
- iPad (`Apps/NibPad`): put the recognizers in a new
  `FingerGestureController` file and keep the hook in `PenCaptureView`
  minimal.
  - Use `UIPanGestureRecognizer` (exactly 2 touches), `UIPinchGestureRecognizer`
    and `UITapGestureRecognizer` (2 and 3 touches), with
    `allowedTouchTypes = [.direct]`. Pan and pinch may recognize
    simultaneously.
  - Palm rejection: ignore finger gestures while a Pencil touch is active
    and for 300 ms after it.
  - Remove the old three-finger HUD tap. 0009 moves the panel to a
    four-finger tap.
  - Send gestures through the sender (a new `sendControl`-style API on
    `PenLinkSender`).
- Mac: `GestureEventBuilder` (NibCore, macOS, pure → `[CGEvent]`):
  - scroll uses `CGEvent(scrollWheelEvent2Source:units: .pixel, …)` with
    `scrollWheelEventIsContinuous = 1` and the scroll phase field set from
    the gesture phase (began 1, changed 2, ended 4, cancelled 8);
  - scale finger travel ×2 so it feels like a trackpad; make the gain a
    constant;
  - zoom is a scroll event with the modifier flag set; map scaleDelta to
    vertical pixels (`(scale − 1) × 400`) and keep the sign consistent:
    pinch out = zoom in;
  - undo/redo are key down/up events for virtual key `Z` (6) with
    `.maskCommand` (`+ .maskShift` for redo).

  `PenLinkReceiver` delivers gestures through a new callback. NibMac posts
  them on the injection worker's queue, so they stay ordered with pen
  events, and only when trusted.
- Coordinate with 0011 (USB, parallel): keep `PenLink.swift` edits small
  and additive.

## Acceptance

- [ ] `GestureEventBuilderTests`:
      - scroll events carry pixel deltas, the continuous flag and the
        phase;
      - zoom carries the right modifier flag and the sign of the delta;
      - undo/redo produce key down/up for keycode 6 with the right flags.
- [ ] `ControlMessage` round-trips every `Gesture` case.
- [ ] Palm-rejection logic is pure and tested: a gesture during or within
      300 ms of Pencil contact is suppressed.
- [ ] Manual checks in Handoff (Krita):
      - two-finger drag pans the canvas;
      - pinch zooms;
      - two-finger tap undoes and three-finger tap redoes;
      - drawing with the Pencil while resting a palm triggers nothing.

      Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Settings UI (0009), USB (0011), rotation gesture, custom shortcut mapping.

## Handoff

```
Branch/commit: t3/finger-gesture-events @ bc1b0dd654da49b8963094edc73aede8aaad79fa
Verify: verify: ok (Test run with 55 tests; NibMac + NibPad built)
Done:
- Added Codable TCP gesture messages and sender/receiver callbacks for scroll, zoom, undo, and redo.
- Added pure palm rejection timing policy and iPad recognizers with Pencil suppression.
- Added macOS Quartz event builder and ordered, Accessibility-gated injection worker handling.
- Added deterministic round-trip, palm policy, and CGEvent tests.
Manual checks: Not run; requires an iPad, Accessibility permission, and Krita. Steps: connect NibPad to NibMac, then verify two-finger pan, pinch zoom, two-finger undo, three-finger redo, and Pencil drawing with a resting palm in Krita.
Not done / risks: Gesture settings use PadSettings() defaults until task 0009 supplies its store. Hardware/Krita behavior remains for manual validation.
```
