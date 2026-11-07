---
id: "0009"
title: iPad companion panel and pressure curve
status: doing
milestone: M2
depends: []
---

## Goal

On the iPad, a four-finger tap opens a readable companion panel where the
user tunes the pressure curve (with live preview) and gesture options. The
curve is applied on the iPad before samples are sent.

## Context

- Shared model already on main: `Packages/NibCore/Sources/NibCore/Settings/PadSettings.swift`
  (`Pressure` softness/minimum/maximum + presets, `Gestures` options). Do
  not rename fields; task 0010 reads `gestures` in parallel.
- `PressureCurve.swift` (NibCore, pure): `apply(_ raw: Float, _ p:
  PadSettings.Pressure) -> Float`. t = clamp((raw − min)/(max − min), 0, 1);
  out = t^γ with γ = 2^(1.5·softness) (soft < 1 < firm). It must be
  monotonic, with 0 → 0 and 1 → 1, and the output must stay in 0…1.
- `PadSettingsStore` (NibPad): load/save JSON in `UserDefaults`, observable.
- Apply the curve in the send path (`NetworkSink.send` or just before it),
  so the HUD can show raw and mapped values. Hover pressure stays 0.
- Panel (SwiftUI overlay on the capture view, opened/closed by a
  **four-finger tap**). The existing three-finger tap moves to task 0010
  (redo); remove it from `PenCaptureView`. While the panel is open,
  restore normal brightness, send no samples to the Mac, and dim again on
  close.
  - **Link:** state and Mac name.
  - **Pressure:** Soft / Linear / Firm presets, a softness slider, a
    min/max range, a drawn curve, and a test strip. Pressing the Pencil
    there moves a marker along the curve (raw → mapped). Nothing is sent
    to the Mac.
  - **Gestures:** toggles for two-finger scroll, pinch zoom and tap
    undo/redo, plus a zoom-modifier picker (⌘ / ⌥ / ⌃). Only the settings
    UI is in scope here; 0010 implements the gestures.
  - **Debug HUD:** a switch (the old HUD: pressure, angles, rate, link).
- Keep UI code out of `PenCaptureView` where practical (new files under
  `Apps/NibPad/`). Do not edit transport files or anything under
  `Apps/NibMac`.

## Acceptance

- [ ] `PressureCurveTests`: endpoints, monotonicity over 100 steps for
      each preset and for extremes, min/max thresholds, output in 0…1.
- [ ] `PadSettingsStore` round-trips through `UserDefaults` (a test with a
      suite-named defaults instance, if NibPad has no test target: put the
      store in NibCore).
- [ ] NibPad builds in verify. A four-finger tap toggles the panel, and no
      three-finger handler remains.
- [ ] Manual checks in Handoff:
      - the panel opens and is readable;
      - Firm vs Soft visibly changes stroke weight in Krita for the same
        hand pressure;
      - the test strip does not draw on the Mac;
      - settings persist across relaunch.

      Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Gesture recognition and Mac injection (0010), USB (0011), Mac-side settings.

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks:
Not done / risks:
```
