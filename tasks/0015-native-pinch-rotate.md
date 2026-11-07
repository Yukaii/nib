---
id: "0015"
title: Native trackpad magnify/rotate gestures from iPad pinch and rotate
status: doing
milestone: M2
depends: []
---

## Goal

A two-finger pinch on the iPad zooms the Mac canvas, and a two-finger twist
rotates it, delivered as macOS trackpad magnify/rotate gesture events, the
way Krita, Photoshop and Affinity already handle a MacBook trackpad.
The existing modifier+scroll zoom stays as a per-profile fallback.

## Context

- Today: `Apps/NibPad/FingerGestureController.swift` sends `Gesture.zoom`
  (per-event `scaleDelta`, phases); the Mac turns it into modifier+scroll in
  `Packages/NibCore/Sources/NibCore/GestureEventBuilder.swift` (see its
  doc comment on modifier press/release; keep that behaviour for the
  fallback). Two-finger pan → `Gesture.scroll` and must keep working while
  pinching/rotating (recognizers run simultaneously).
- macOS has no public API to synthesize trackpad gestures. The known route is
  a `CGEvent` of the private gesture type (`kCGSEventGesture`, raw type 29)
  with private integer/double fields for the gesture HID subtype
  (magnify/zoom vs rotate), the magnification / rotation value, and the
  gesture phase; posting a gesture event typically needs a begin and end
  event around the changes. Research the exact field numbers and sequence
  from public sources (open-source projects that synthesize magnify/rotate,
  e.g. utilities for trackpad emulation; read only, keep license rules in
  AGENTS.md) and document what you used, with links, in a new
  `docs/decisions/0007-native-gesture-events.md` (≤ 60 lines: approach,
  fields, risks: private, may break on macOS updates, fallback).
- Build the builder as `NativeGestureEventBuilder` (macOS, NibCore) producing
  `[CGEvent]` for magnify(delta, phase) and rotate(degrees, phase); keep the
  raw field numbers as named constants in one place.
- Add `nib-gesture-demo` executable (like `nib-inject-demo` in
  `Packages/NibCore/Package.swift`): after a 3 s countdown, posts a slow
  magnify in, magnify out, rotate +45°, rotate −45° to the frontmost app,
  so the user can verify in Krita without an iPad. Print what it posts.
- Protocol: add `Gesture.rotate(degreesDelta: Double, phase: Phase)`
  (Codable like the others). Zoom keeps `Gesture.zoom`.
- iPad: add a `UIRotationGestureRecognizer` simultaneous with pinch and pan;
  per-event delta like pinch (reset `rotation` to 0 each change); always end
  a begun rotation (same rule as pinch); small dead zone so a plain pinch
  does not rotate (ignore until |total| > 8°, then send).
- Settings (`PadSettings.Gestures`, per profile; decodeIfPresent defaults):
  `zoomMethod: nativeGesture | modifierScroll` (default nativeGesture) and
  `rotate: Bool` (default true). The zoom modifier only matters for
  modifierScroll. Send the method with each zoom gesture (Mac stays
  stateless): add a field to `Gesture.zoom` with a decode default of
  modifierScroll for old senders, or a separate case — your choice, tested.
  Show both options in the profile editor's gesture section
  (`Apps/NibPad/ProfileEditor.swift`).
- Mac routing in `PenInjectionController.handle(_ gesture:)`: native zoom
  and rotate → `NativeGestureEventBuilder`; modifierScroll → existing path.
  Release rules: a begun native gesture must be ended on session end (post
  the end event), like held modifiers.

## Acceptance

- [ ] `NativeGestureEventBuilder` tests: magnify began/changed/ended and
  rotate produce events of the documented raw type with the documented field
  values (read back via `getIntegerValueField`/`getDoubleValueField` with the
  raw field numbers), sign conventions (pinch out = zoom in; twist
  counter-clockwise = positive), and session-end emits the end event.
- [ ] `Gesture.rotate` and the zoom method round-trip through
  `ControlFramer`/`StreamFramer`; old zoom JSON without a method decodes as
  modifierScroll; old settings JSON decodes with the new defaults.
- [ ] `swift run --package-path Packages/NibCore nib-gesture-demo --help`
  prints usage and exits 0 without posting anything.
- [ ] Decision 0007 written; `scripts/verify.sh` passes.

## Out of scope

- Per-app keyboard rotation shortcuts, rotation reset, three-finger gestures.
- Changing pan/scroll or pen events.

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks: run nib-gesture-demo with Krita in front (needs Accessibility
  for the terminal): canvas zooms in/out and rotates. Then iPad: pinch zooms,
  twist rotates in Krita; scroll still works. (needs Mac + Krita + iPad)
Not done / risks:
```
