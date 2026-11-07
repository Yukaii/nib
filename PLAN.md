# Plan

Started 2026-11-07. Integration branch: `main`. Keep under 120 lines.

## Current focus

M2 — drawing companion, app-aware. Pencil dropouts were an iPadOS/Pencil
pairing bug (fixed by re-pairing). Next: per-app profiles (0012), then edge
shortcut buttons + strip (0013) and the iPad profile editor (0014) in parallel.

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
- [x] 0009 iPad companion panel (four-finger tap) + pressure curve applied on iPad
- [x] 0010 Finger gestures: two-finger scroll, pinch zoom, 2/3-finger tap undo/redo
- [x] 0011 USB-C mode via usbmuxd, preferred over Wi-Fi
- [x] 0012 Per-app profiles model, front-app reporting, key shortcuts on the Mac
- [ ] 0013 iPad edge controls: shortcut buttons + scroll/zoom/brush strip
- [ ] 0014 iPad profile editor in the companion panel
- [ ] Latency budget (target < 20 ms pen-to-event on Wi-Fi)
- [ ] Active-area mapping: aspect-locked letterbox, region selection, multi-display
- [ ] Eraser via Pencil double-tap / squeeze (toggle exists; verify in apps)
- [ ] Hover → proximity + cursor move (Pencil Pro / iPad mini 7)

### M3 — Polish

- [ ] Keep-awake and minimal-brightness screen-off behaviour, palm rejection
- [ ] Signed builds / install docs

## Decisions

- 0001 Native iPad app + native Mac host, not a browser client
- 0002 Wire protocol: fixed 40-byte little-endian `PenSample` packets
- 0003 Injection via `CGEvent` tablet point + proximity events
- 0004 Transport: Bonjour TCP control + UDP 40-byte samples
- 0005 USB-C mode via usbmuxd, type-tagged stream, preferred over Wi-Fi
- 0006 Per-app profiles owned by the iPad; keys as `Gesture.key`
