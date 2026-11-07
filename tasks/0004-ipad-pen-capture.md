---
id: "0004"
title: iPad screen-off pen capture view
status: doing
milestone: M1
depends: []
---

## Goal

NibPad shows a black full-screen surface that turns every Apple Pencil touch
and hover into `PenSample` values (pressure, tilt, hover, coalesced samples),
ignores fingers, and can show a debug HUD of the live values.

## Context

- `PenSample` is in `Packages/NibCore/Sources/NibCore/PenSample.swift`; the
  field meanings are in `docs/decisions/0002-wire-protocol.md`.
- Put the testable math in NibCore as `PencilNormalizer.swift`
  (platform-agnostic, no UIKit): input = location, view size, force,
  maximumPossibleForce, altitude, azimuth, optional hover zOffset; output =
  normalized x/y (clamped 0…1), pressure (force/max, clamped, 0 if max is 0),
  altitude clamped 0…π/2, azimuth normalized into 0…2π, hoverDistance UInt16.
  Tests in `PencilNormalizerTests.swift`.
- In `Apps/NibPad/`:
  - `PenCaptureView` (UIView, wrapped for SwiftUI): handle only
    `touch.type == .pencil`; use `coalescedTouches(for:)` (flag `.coalesced`)
    and `predictedTouches(for:)` (flag `.predicted`); `azimuthAngle(in:)`;
    kinds down/move/up/cancel; monotonically increasing `sequence`;
    timestamp from `touch.timestamp` in ns.
  - Hover: `UIHoverGestureRecognizer` → `.hover` samples with `zOffset`,
    altitude/azimuth when available; end of hover → `.proximityExit`.
  - `UIPencilInteraction`: double-tap and squeeze toggle the eraser bit in
    `buttons` (keep it simple: a toggle).
  - Output through a protocol `PenSampleSink { func send(_: PenSample) }`;
    for now a `LoggingSink` that keeps the latest sample.
  - Screen-off behaviour: `isIdleTimerDisabled = true` while active; dim
    to minimum brightness while active and restore on background.
  - Debug HUD toggled by a three-finger tap: pressure bar, altitude,
    azimuth, hover, sample rate (Hz) and a fading ink trace. Hidden by
    default (pure black).
- Target: iPad mini 6/7, landscape and portrait, iPadOS 18+.

## Acceptance

- [ ] `PencilNormalizer` tests: corners and outside-bounds clamping,
      pressure with max 0, azimuth wrap from negative values, hover mapping
      0 → 0 and 1 → 65535.
- [ ] NibPad builds in verify (unsigned, generic iOS).
- [ ] Manual check steps in Handoff (install on iPad mini, open HUD, press
      harder → pressure bar rises; tilt → altitude changes; finger draws
      nothing). Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Networking (task 0005), Mac side, settings UI.

## Handoff

```
Branch/commit: t3-15dfc55b @ b64392a026c2ec10f39e1cddc14fa725ef8fb3d7
Verify: verify: ok (Test run with 5 tests; NibMac + NibPad built)
Done:
- Added platform-neutral PencilNormalizer with bounds, pressure, angle, and hover mapping.
- Added deterministic normalizer tests for clamping, zero-force maximum, azimuth wrapping, and hover endpoints.
- Added UIKit Pencil capture surface with pencil-only touch handling, coalesced/predicted samples, hover/proximity events, sequence/timestamp generation, eraser toggle tap/squeeze, and LoggingSink.
- Added black full-screen SwiftUI wrapper, screen-off brightness/idle behavior, and three-finger debug HUD with pressure, pose, hover, rate placeholder, and trace.
Manual checks: Not run (requires iPad mini hardware). Install the unsigned NibPad build on an iPad mini, open the HUD with a three-finger tap, press harder to see the pressure bar rise, tilt to see altitude change, and draw with a finger to confirm no samples are emitted.
Not done / risks: Sample-rate HUD currently displays 0 Hz; networking remains task 0005.
```
