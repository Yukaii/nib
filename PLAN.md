# Plan

Started 2026-11-07. Integration branch: `main`. Keep under 120 lines.

## Current focus

Product phase (decided 2026-11-07): free, open-source; notarized DMG for the
Mac, App Store for the iPad, GitHub Sponsors. Rust hosts later (M5).

**Paused 2026-11-08 for about two weeks of daily use** by the user; the repo
went public as a developer preview the same day. Reprioritize the remaining M3
items and M4 from that experience before starting new tasks.

Done in M3: protocol v2, CI, onboarding, pairing and encrypted sessions
(confirmed on device over Wi-Fi and USB), transport tidy-up, iPad settings,
Mac settings window with edge margin.

## Milestones

### M0 — Workflow foundation

- [x] Repo, AGENTS/PLAN/tasks, NibCore package, XcodeGen apps, verify gate

### M1 — Pressure reaches the Mac (hard requirement)

- [x] 0002–0006 wire codec, CGEvent injector, pen capture, transport, host app
- [x] Exit check passed 2026-11-07 (user, iPad mini 7, Krita)

### M2 — Feels like a Wacom

- [x] 0007–0015 diagnostics, jitter buffer, companion panel, finger gestures,
  USB-C, per-app profiles, edge controls, profile editor, native pinch/rotate
- [ ] Latency budget (target < 20 ms pen-to-event on Wi-Fi)
- [ ] Eraser via Pencil double-tap / squeeze (toggle exists; verify in apps)
- [ ] Hover → proximity + cursor move (Pencil Pro / iPad mini 7)

### M3 — Product foundations

- [x] 0016 Protocol v2: platform-neutral key chords + settings migration
- [x] 0017 Protocol v2: handshake (host info, capabilities, device ID, versions)
- [x] 0018 Language-neutral protocol spec + golden test vectors
- [x] 0019 CI: GitHub Actions runs verify; FUNDING.yml
- [x] 0020 Mac onboarding: setup window, Accessibility + auto-relaunch,
  pressure test canvas, launch at login
- [x] 0021 iPad onboarding: welcome, choose a Mac, pressure check, gesture guide
- [x] 0022 Pairing core: commit-reveal numeric code, proofs, transport handling
- [x] 0024 Pairing UI on Mac and iPad, Keychain keys, retire the allow list
- [x] 0025 Re-pairing after Forget works from either side
- [x] 0026 Pairing over USB: USB wins over Wi-Fi before sign-in too
- [x] 0023 Encrypted sessions: ChaCha20-Poly1305 (confirmed on device 2026-11-08)
- [x] 0027 Transport tidy-up: USB arming race, Wi-Fi backoff on cable, log nits
- [x] 0028 iPad settings: sectioned panel, plain wording, Advanced for debug
- [x] 0029 Mac settings window: display, active area, multi-display
- [ ] Keep-awake, minimal brightness, palm rejection review

Exit check (manual): a fresh Mac user account and a reset iPad reach a
pressure stroke in Krita by following only on-screen instructions.

### M4 — Release 1.0

- [ ] Developer ID signing + notarized DMG built in CI on tag
- [ ] Auto-update for the Mac app (decide: Sparkle or GitHub-release check)
- [ ] iPad: TestFlight beta, then free App Store release
- [ ] Protocol v2 frozen: additive changes only after 1.0
- [ ] README/site: install, supported hardware, Sponsors

### M5 — Windows and Linux hosts (Rust)

- [ ] Rust core crate: protocol (passes `protocol/vectors`), mapping, jitter buffer
- [ ] Linux host spike: `uinput` virtual tablet with pressure + tilt in Krita
- [ ] Windows host spike: `InjectSyntheticPointerInput` (`PT_PEN`) in Krita
- [ ] USB via usbmuxd on both (libimobiledevice / Apple Mobile Device Service)

## Decisions

- 0001 Native iPad app + native Mac host, not a browser client
- 0002 Wire protocol: fixed 40-byte little-endian `PenSample` packets
- 0003 Injection via `CGEvent` tablet point + proximity events
- 0004 Transport: Bonjour TCP control + UDP 40-byte samples
- 0005 USB-C mode via usbmuxd, type-tagged stream, preferred over Wi-Fi
- 0006 Per-app profiles owned by the iPad; keys as `Gesture.key`
- 0007 Native magnify/rotate gesture events (undocumented fields)
- 0008 Protocol v2: W3C key codes, `primary` modifier, host capabilities
- 0009 Distribution: notarized DMG (Mac, not sandboxed), App Store (iPad)
- 0010 Windows/Linux hosts in Rust; the Mac host stays Swift
- 0011 Pairing by numeric comparison; app-layer AEAD sessions
