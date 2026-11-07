---
id: "0006"
title: NibMac wiring — receive, map to display, inject; Accessibility onboarding
status: doing
milestone: M1
depends: ["0003", "0005"]
---

## Goal

The NibMac menu-bar app receives Pencil samples from NibPad, maps them
aspect-locked onto a chosen display, and injects tablet events with
pressure, so drawing on the iPad draws in Krita on the Mac.

## Context

- Read decisions 0003 (injection) and 0004 (transport). Building blocks
  in NibCore: `PenLinkReceiver` (accept hook, samples, session events),
  `TabletEventBuilder` (repairs transitions, drops `.predicted`),
  `TabletInjector` (`isTrusted`, `post`).
- `DisplayMapper.swift` (NibCore, platform-agnostic, pure): maps a
  sample's normalized x/y on an iPad surface of size S onto a display
  rect D in global top-left-origin coordinates (`CGDisplayBounds`, same
  space as `CGEvent.location`). Aspect lock = "force proportions" like
  Wacom: the **whole display is reachable**; the iPad's active area is the
  largest centered sub-rect of S with D's aspect, and points outside it
  clamp to the display edge. Clamp to stay inside D (max x/y just under
  `maxX`/`maxY`). S of 0×0 → map the full surface without aspect lock.
- `PenInjectionController` (NibCore, macOS): owns a `TabletEventBuilder`
  and a mapper config; takes a `post: ([CGEvent]) -> Void` closure (real
  one = `TabletInjector`) so it is testable. `handle(sample)`,
  `surfaceChanged(_:)`, `displayChanged(_:)`, and `sessionEnded()`.
  `sessionEnded()` must release a held button and exit proximity by
  feeding a synthetic `.proximityExit` through the builder. If
  `isTrusted` is false, it posts nothing and reports that so the UI can
  show it.
- `Apps/NibMac`:
  - Starts `PenLinkReceiver` at launch. Accept hook: an `NSAlert`
    "Allow “<iPad name>” to control your pointer?" with Allow / Deny and
    a "Remember" checkbox (UserDefaults by device name; note in Handoff
    that this is not authentication).
  - helloAck carries the chosen display's size in points. If
    `PenLinkReceiver` has no way to set it, add a minimal property; keep
    any Transport edit small.
  - Menu: status line (waiting / connected to X / rejected), an
    Accessibility line, a "Display" submenu listing `NSScreen.screens`
    by `localizedName` with a checkmark (choice persisted by display ID,
    default main), and Quit. Recompute bounds on
    `NSApplication.didChangeScreenParametersNotification`.
  - Accessibility onboarding: if not trusted, a "Grant Accessibility…"
    item calls `AXIsProcessTrustedWithOptions` with the prompt option and
    opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
    Re-check every 1 s until trusted, then update the menu.
  - `session .disconnected` → `sessionEnded()`.
- `docs/architecture.md`: update it to describe what exists after this
  task (≤ 150 lines).

## Acceptance

- [ ] `DisplayMapperTests`: corners map to display corners (wider and
      taller displays), a point in the dead band clamps to the edge, a
      display with a negative origin (left of main), and 0×0 surface.
- [ ] `PenInjectionControllerTests` with a recording `post`: a
      down/move/up stroke posts events at mapped points with pressure;
      `sessionEnded()` mid-stroke posts leftMouseUp then a proximity
      exit; untrusted posts nothing.
- [ ] NibMac builds in verify.
- [ ] Manual checks in Handoff (the M1 exit check): grant Accessibility,
      run NibPad, allow the iPad, draw in Krita with a pressure brush →
      thin-to-thick strokes on the chosen display; switch display in
      the menu; quit NibPad mid-stroke → no stuck mouse button within ~3 s.
      Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Pressure curves, hover cursor tuning, USB, pairing, latency work (M2).

## Handoff

Filled in by the worker:

```
Branch/commit: t3/mac-host-wiring @ b802ccc
Verify: verify: ok (Test run with 40 tests; NibMac + NibPad built)
Done:
- Added aspect-locked DisplayMapper with display-edge clamping and geometry tests.
- Added PenInjectionController wiring mapped samples through TabletEventBuilder and TabletInjector, including session cleanup and Accessibility trust gating.
- Wired NibMac receiver, iPad consent prompt, remembered device-name decisions, display picker, display-change updates, status, and Accessibility onboarding.
- Added pressure-path tests that inspect posted tablet event pressure fields.
- Updated architecture documentation and helloAck display dimensions.
Manual checks: Grant Accessibility, run NibPad, allow the iPad, draw in Krita with a pressure brush, switch display, and quit NibPad mid-stroke; not run (no iPad/Krita session available).
Review fixes (orchestrator): @StateObject so the menu updates; trust
  check cached (refreshed by the 1 s timer) instead of per sample; app
  activates before the Allow prompt.
Not done / risks: Remembered device names are a convenience policy only and are not authentication; real-device latency and pressure behavior still require the M1 exit check.
```
