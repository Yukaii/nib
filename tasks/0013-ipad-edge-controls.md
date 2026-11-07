---
id: "0013"
title: iPad edge controls — shortcut buttons and scroll/zoom strip
status: doing
milestone: M2
depends: ["0012"]
---

## Goal

While drawing, a column of shortcut buttons on one iPad edge and a slide
strip on the other edge act like Wacom ExpressKeys and a touch ring, using
the active profile from 0012.

## Context

Spec: `docs/decisions/0006-app-profiles-and-shortcuts.md`. 0012 added
`Profile.buttons`, `Profile.strip`, `Gesture.key`, and `NetworkSink`'s
active profile.

- Capture view: `Apps/NibPad/PenCaptureView.swift` (Pencil-only drawing,
  screen dimmed to brightness 0, HUD, panel). Finger gestures:
  `Apps/NibPad/FingerGestureController.swift` (two-finger pan, pinch, taps,
  palm rejection via `GesturePalmRejection`).
- Add an edge-controls view (new file, e.g. `Apps/NibPad/EdgeControlsView.swift`)
  laid over the capture view: buttons on the side opposite the strip
  (`strip.side`), each ~64 pt tall, ~72 pt wide, labels from the profile.
  **Finger touches only**: the Pencil must keep drawing everywhere, including
  over the controls (Pencil touches pass through to the capture view).
- Button behaviour: `hold == false` → `key(chord, tap)` on touch up inside;
  `hold == true` → `down` on touch down, `up` on touch end **or cancel**.
  Light haptic on press if available.
- Strip: vertical finger slide. Pure step logic in NibCore for tests
  (e.g. `Settings/StripStepper.swift`: accumulates points → emits whole steps,
  resets on end). `scroll` mode → `Gesture.scroll` with began/changed/ended
  phases; `zoom` → `Gesture.zoom` with the profile's zoom modifier and
  began/ended phases; `brushSize` → `key` tap `]` per step up, `[` per step
  down (step ≈ 24 pt); `off` hides the strip.
- Touches that start in an edge control must not start two-finger pan /
  pinch / tap gestures, and vice versa (`gestureRecognizer(_:shouldReceive:)`
  can test the touch location).
- Visibility: the screen is at brightness 0 while drawing. Draw controls in
  dark gray outlines with labels at ~25% white so they are faintly visible
  when the user raises brightness; add a PadSettings value `edgeBrightness`
  (0…0.3, default 0.08) applied instead of 0 while edge controls are shown
  (see `applyBrightness()` in `PenCaptureView`). Keep HUD/panel behaviour.
- Edge controls are part of the iPad surface; the pen mapping keeps using the
  whole surface (no geometry change in this task).

## Acceptance

- [ ] `StripStepper` tests: 50 pt up with 24 pt steps → 2 up steps and 2 pt
  carried; direction change; reset on end; zero/NaN input ignored.
- [ ] Tests (NibCore, pure) for the button → gesture mapping: tap button emits
  one `key(tap)`; hold emits `down` then `up` on end and on cancel.
- [ ] Pencil drawing over an edge control still produces pen samples (code
  path: controls ignore `.pencil` touches; reviewed).
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Editing profiles/buttons (0014). Hover. Changing the pen mapping area.

## Handoff

```
Branch/commit: t3/ipad-edge-controls @ 9a1508650ec6576b6c9c0da217165c5bd6ab99b4
Verify: verify: ok (Test run with 84 tests; NibMac + NibPad built)
Done:
- Added faint edge shortcut buttons with tap and hold/cancel key lifecycle mapping.
- Added scroll, zoom, and brush-size vertical strip controls with pure StripStepper logic.
- Edge controls reject Pencil hit testing, exclude edge touches from finger recognizers, and refresh from the active front-app profile.
- Added configurable PadSettings.edgeBrightness (default 0.08, clamped to 0...0.3).
- Added deterministic NibCore tests for strip stepping and button gesture mapping.
Manual checks: in Krita, tap B/E buttons switch tools; hold Space + Pencil
  pans; strip in brushSize mode resizes the brush; two-finger scroll still
  works away from the edges; Pencil draws over the controls. (not run; needs iPad + Krita)
Not done / risks: Hardware/Krita checks remain manual. Profile editor UI is task 0014.
```
