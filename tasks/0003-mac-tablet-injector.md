---
id: "0003"
title: Mac tablet event injector and pressure-ramp demo
status: doing
milestone: M1
depends: []
---

## Goal

Prove the hard requirement on the Mac side: synthesized events reach apps as
**pen tablet events with pressure and tilt**. A CLI draws a scripted stroke
whose pressure ramps 0→1→0, and Krita shows a thin-thick-thin line.

## Context

- Read `docs/decisions/0003-cgevent-tablet-injection.md` first; it is the
  design. If you find it wrong (e.g. an app needs extra fields), fix the code
  and describe the needed doc change in Handoff.
- Add to NibCore (all macOS parts behind `#if os(macOS)`):
  - `TabletMath.swift` (platform-agnostic): `tilt(altitude:azimuth:) ->
    (x: Double, y: Double)` per decision 0003, clamped to −1…1.
  - `TabletEventBuilder.swift` (macOS): pure function(s) that build
    `[CGEvent]` for a `PenSample` plus a target `CGPoint` in global display
    coordinates and a state (in proximity? button down?). Must emit proximity
    enter/exit, down/drag/up with `.mouseEventSubtype = tabletPoint`,
    `.tabletEventPointPressure`, `.mouseEventPressure`, `.tabletEventTiltX/Y`,
    `.tabletEventDeviceID` / `.tabletProximityEventDeviceID` consistent,
    pointer type pen or eraser from `buttons`. Keep state in a small
    `TabletEventBuilder` struct, not globals.
  - `TabletInjector` (macOS): posts built events to `.cghidEventTap`; has
    `static var isTrusted: Bool` via `AXIsProcessTrusted()`.
- Add an executable target `nib-inject-demo` in `Packages/NibCore/Package.swift`
  (macOS only): checks Accessibility (prints how to grant if missing), waits 3 s,
  then draws an S-curve ~400 pt wide starting at the current mouse location
  over ~1.5 s at 240 Hz with pressure `sin(πt)` and a tilt sweep.
- Glass (MIT, github.com/Ntarasiuk/glass) forwards Pencil pressure on macOS;
  a shallow clone into `.cache/` to read its injection code is allowed.

## Acceptance

- [ ] Tests (no permission needed): build events for a down/move/up sequence,
      convert each with `NSEvent(cgEvent:)`, and assert `.subtype ==
      .tabletPoint`, `.pressure` matches within 0.01, `.tilt` matches, and the
      proximity events carry `.tabletProximity` type with enter true/false.
- [ ] `TabletMath` tests: perpendicular pen → (0,0); flat at azimuth 0 → (1,0);
      flat at π/2 → (0,1); clamping.
- [ ] `swift run --package-path Packages/NibCore nib-inject-demo` builds.
- [ ] Manual check written in Handoff: run demo with Krita open on a canvas
      with a pressure-sensitive brush; expected thin-thick-thin stroke. Say
      whether you ran it (you likely cannot: say so, the orchestrator will).
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Networking, display mapping, the NibMac app UI, DriverKit.

## Handoff

```
Branch/commit: t3/mac-tablet-injector @ 6f450593c5ddf0d22cf3094bbb2d8c5cc4cd9274
Verify: verify: ok (Test run with 5 tests; NibMac + NibPad built)
Done:
- Added TabletMath tilt conversion with clamping and deterministic tests.
- Added stateful macOS CGEvent tablet/proximity builder with stable device IDs, pen/eraser pointer types, capability mask, tilt, and pressure in both Quartz fields.
- Added TabletInjector Accessibility check and HID event posting.
- Added the macOS pressure-ramp S-curve `nib-inject-demo` executable.
- Added NSEvent round-trip coverage for pressure, tilt, subtype, and proximity lifecycle.
Manual checks: Run `swift run --package-path Packages/NibCore nib-inject-demo` with Krita open on a pressure-sensitive canvas; verify a thin-thick-thin S-curve. Not run (requires Accessibility permission and Krita).
Not done / risks: Real drawing-app behavior and capability-mask interpretation still require the orchestrator's manual Krita check; no decision document change was needed.
```
