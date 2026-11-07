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
Branch/commit: t3/fix-mac-tablet-injector-review @ f5b2316
Verify: verify: ok (Test run with 26 tests; NibMac + NibPad built)
Done:
- Corrected the IOKit tablet capability mask and added stable proximity pointer/vendor IDs.
- Made button and proximity state resilient to missing, duplicate, and out-of-order samples; deferred eraser changes across an active stroke.
- Added explicit tablet button/click fields, predicted-sample filtering, and full lifecycle/state transition tests.
- Fixed the demo's normalized sample coordinates and Accessibility guidance.
Manual checks:
- Build/run: `swift run --package-path Packages/NibCore nib-inject-demo`.
- When prompted, grant the terminal app running `swift run` (Terminal, iTerm, etc.) access under System Settings › Privacy & Security › Accessibility.
- Open Krita, create a new canvas, select a pressure-size brush such as “Basic-5 Size”, then open Settings › Configure Krita › Tablet settings tester and watch the pressure/tilt values.
- Expected result: the demo draws a thin-thick-thin S-curve of about 400 pt width while the tester shows changing pressure and tilt.
- Not run: this requires Accessibility permission, Krita, and a live desktop session.
Not done / risks: Real drawing-app behavior remains for the orchestrator's manual Krita check; no decision document change was needed.
```
