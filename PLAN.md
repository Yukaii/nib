# Plan

Started 2026-11-07. Integration branch: `main`. Keep under 120 lines.

## Current focus

M1 — prove the hard requirement end to end: a Pencil stroke on the iPad
arrives in Krita on the Mac with varying pressure.

## Milestones

### M0 — Workflow foundation

- [x] Repo, AGENTS/PLAN/tasks, NibCore package, XcodeGen apps, verify gate (orchestrator)

### M1 — Pressure reaches the Mac (hard requirement)

- [x] 0002 Wire protocol codec for `PenSample` (NibCore)
- [ ] 0003 Mac tablet event injector + `nib-inject-demo` pressure-ramp CLI
- [x] 0004 iPad screen-off pen capture view (force, tilt, hover, coalesced)
- [ ] 0005 Transport: Bonjour/Network.framework sender (iPad) + receiver (Mac)
- [ ] 0006 Mac host app wiring: receive → map → inject, display picker, Accessibility onboarding

Exit check (manual): draw in Krita on the Mac from the iPad mini with a
visible thin-to-thick pressure stroke.

### M2 — Feels like a Wacom

- [ ] Latency budget and measurement (target < 20 ms pen-to-event on Wi-Fi)
- [ ] Wired USB-C path (usbmux) for lower jitter
- [ ] Active-area mapping: aspect-locked letterbox, region selection, multi-display
- [ ] Pressure curve settings; eraser via Pencil double-tap / squeeze
- [ ] Hover → proximity + cursor move (Pencil Pro / iPad mini 7)

### M3 — Polish

- [ ] Keep-awake and minimal-brightness screen-off behaviour, palm rejection
- [ ] Shortcut buttons on the iPad edge (undo, brush size) as keyboard events
- [ ] Signed builds / install docs

## Decisions

- 0001 Native iPad app + native Mac host, not a browser client
- 0002 Wire protocol: fixed 40-byte little-endian `PenSample` packets
- 0003 Injection via `CGEvent` tablet point + proximity events
- 0004 Transport: Bonjour TCP control + UDP 40-byte samples
