# Plan

Started 2026-11-07. Integration branch: `main`. Keep under 120 lines.

## Current focus

M2 — feel like a Wacom. First: measure the link, then smooth it (cursor
moves in bursts: 240 Hz samples arrive ~4 per 60 Hz iPad frame, plus Wi-Fi
jitter, and the Mac receives on the main thread).

## Milestones

### M0 — Workflow foundation

- [x] Repo, AGENTS/PLAN/tasks, NibCore package, XcodeGen apps, verify gate (orchestrator)

### M1 — Pressure reaches the Mac (hard requirement)

- [x] 0002 Wire protocol codec for `PenSample` (NibCore)
- [x] 0003 Mac tablet event injector + `nib-inject-demo` pressure-ramp CLI
- [x] 0004 iPad screen-off pen capture view (force, tilt, hover, coalesced)
- [x] 0005 Transport: Bonjour/Network.framework sender (iPad) + receiver (Mac)
- [x] 0006 Mac host app wiring: receive → map → inject, display picker, Accessibility onboarding

- [x] Exit check passed 2026-11-07 (user, iPad mini 7): pressure reaches the
  Mac. Note: Accessibility granted while NibMac runs needs an app restart.

Exit check (manual): draw in Krita on the Mac from the iPad mini with a
visible thin-to-thick pressure stroke.

### M2 — Feels like a Wacom

- [x] 0007 Link diagnostics: logging, stats (rate, loss, jitter, RTT), HUD brightness
- [x] 0008 Smooth delivery: off-main receive, adaptive jitter buffer, low-latency network params
- [ ] Latency budget (target < 20 ms pen-to-event on Wi-Fi)
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
