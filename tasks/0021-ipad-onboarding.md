---
id: "0021"
title: iPad onboarding — welcome, choose a Mac, pressure check, gesture guide
status: doing
milestone: M3
depends: ["0017"]
---

## Goal

A new user who opens Nib on the iPad sees what to do instead of a black
screen. The flow: install the Mac app, pick their Mac from a list, check that
the Pencil reports pressure, learn the gestures, then start drawing on a black
screen. When the link drops while drawing, a dim status tells them why.

## Context

- Today `NibPadApp.swift` shows `PenCaptureView` (black) immediately. Settings
  open only with a four-finger tap, which nothing tells the user about. Follow
  AGENTS.md "Product quality bar" and the supported-hardware rules.
- **Choose a Mac**: `PenLinkSender` connects to `results.first`
  (`PenLink.swift`). Expose the browse results (service names) and let the app
  pick one. Remember the choice by service name and connect to it
  automatically when it is present. With exactly one Mac, select it without
  asking. Rejected / version mismatch (`helloAck.reason`, from 0017) shows the
  reason and a next step. Show USB as a separate "Connected by cable" state
  (`UsbLinkListener`); USB still wins when present.
- **Onboarding screens** (SwiftUI over the capture view, shown while
  `onboardingCompleted` is false):
  1. Welcome
  2. Install Nib on your Mac: link `https://github.com/Yukaii/nib#install`,
     kept in one place
  3. Choose your Mac: list, searching state, and a Local Network permission
     hint if nothing is found after ~10 s
  4. Pencil check: a pad that reads `force / maximumPossibleForce`. Pass when
     a stroke spans a range of pressures. If strokes arrive but force stays
     constant/zero, say "This Pencil doesn't report pressure. Nib needs Apple
     Pencil (1st gen), Apple Pencil 2 or Apple Pencil Pro." The user can
     continue, but the warning stays visible in the panel.
  5. Gestures: a short illustrated list. Four-finger tap = settings (most
     important), two-finger scroll, pinch/twist, two/three-finger tap
     undo/redo.
  6. Start drawing: the screen goes black.
- **Drawing state**: while not connected, the black screen shows one dim,
  centered line ("Looking for <Mac>…" / "Reconnecting…") plus "Four-finger tap
  for settings". It hides once connected. No status text while connected and
  drawing.
- Companion panel: replace the raw `Link: <state>` with a plain status
  (from 0017's host info) and a **Change Mac** button. Add **Show
  introduction again**.
- Keep the testable parts in NibCore: Mac selection policy (remembered / single
  / ask) and the pressure-check classifier (enough samples, spread of values →
  ok / noPressure / notEnoughData).

## Acceptance

- [ ] Tests: selection policy (remembered present → it; one result → it; several
  without memory → ask; remembered absent → ask). Pressure classifier
  (all-zero, constant 1.0, real ramp, too few samples).
- [ ] `PenLinkSender` no longer auto-connects to `results.first` when several
  Macs are present (test or code inspection noted in Handoff).
- [ ] `scripts/verify.sh` passes.
- [ ] Manual checks written in Handoff (delete and reinstall NibPad; walk the
  flow with NibMac running; quit NibMac and see the reconnecting line; reopen
  the intro from the panel). Say whether you ran them.

## Out of scope

- Pairing codes / encryption (later M3 task).
- Restructuring the rest of the companion panel (later M3 task).
- Custom illustrations: SF Symbols are fine.

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks:
Not done / risks:
```
