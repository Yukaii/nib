---
id: "0007"
title: Link diagnostics — logging, live stats, HUD brightness
status: doing
milestone: M2
depends: []
---

## Goal

Make the link's quality measurable: NibMac shows live rate, loss, jitter
and round-trip time, both apps log session events with `os.Logger`, and the
debug HUD on the iPad is readable.

## Context

- User report after M1: the cursor moves unevenly (bursty), and the link
  sometimes drops. Task 0008 will add a jitter buffer; this task provides the
  numbers to tune and verify it. Do not change delivery timing here.
- Logging: `Logger(subsystem: "dev.yukai.nib", category: …)` in NibCore
  transport (session accepted/rejected/busy, timeout, reconnect, listener
  failure), NibMac (Accessibility state changes, display changes), NibPad
  (link state changes). Never log per sample.
- `LinkStats.swift` (NibCore, pure): `record(sequence:senderTimestampNs:arrivalNs:)`
  and `snapshot(nowNs:) -> LinkStats.Snapshot` over a sliding 2 s window:
  sample rate (Hz), loss % (sequence gaps; duplicates from triple-send
  must not count as received twice or as loss), inter-arrival gap p50/p95/max
  (ms), and delay variation p50/p95 (ms): `arrival − senderTimestamp` minus
  its window minimum (clocks differ; only variation matters).
- RTT probe: add `ControlMessage.probe(sentAtNs: UInt64)` and
  `.probeReply(sentAtNs: UInt64)`. The Mac sends a probe each second, the iPad
  replies at once, and the Mac computes RTT (keep the last and a 10-sample
  median). Leave `ping` and its golden test unchanged, and never reply to a
  reply (task 0005 removed an echo loop).
- Feed `LinkStats` from `PenLinkReceiver` (arrival time from
  `DispatchTime.now().uptimeNanoseconds`) and expose a snapshot accessor or
  callback. NibMac adds one menu line, refreshed each second while
  connected: `238 Hz · loss 0.4% · gap p95 17 ms · jitter p95 9 ms · RTT 6 ms`.
  It also logs the same line every 5 s at `.info`.
- NibPad HUD: showing the HUD restores the user's original brightness, and
  hiding it dims again (`PenCaptureView`). Add the RTT to the HUD if the iPad
  side has it (optional).
- Files: `Transport/` and new `LinkStats.swift` in NibCore, `Apps/NibMac`,
  `Apps/NibPad`. Do not touch `TabletEventBuilder` / `PenInjectionController`.

## Acceptance

- [ ] `LinkStatsTests`: steady 240 Hz input → ~240 Hz, 0% loss, gap p50
      ≈ 4.2 ms; bursty input (4 samples every 16.7 ms) → gap p95 ≈ 16.7 ms;
      a gap of 10 sequences → loss matches; triplicated transitions do not
      count as loss; constant clock offset → delay variation ≈ 0.
- [ ] `ControlFramerTests` round-trip `probe` / `probeReply`; existing
      ping golden test unchanged.
- [ ] Manual checks in Handoff: draw for 30 s and read the NibMac menu line;
      `log stream --predicate 'subsystem == "dev.yukai.nib"'` shows session
      events; three-finger tap → HUD readable at normal brightness, tap again →
      dark. Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Jitter buffer, threading or network-parameter changes (0008).

## Handoff

Filled in by the worker:

```
Branch/commit: t3/link-diagnostics @ 81667fd99afdf579af5702eb87687edcea5d74a3
Verify: verify: ok (Test run with 43 tests; NibMac + NibPad built)
Done:
- Added pure two-second LinkStats measurements for rate, sequence loss, inter-arrival gaps, and delay variation, with deterministic tests.
- Added probe/probeReply control messages and ten-sample median RTT measurement while preserving ping behavior.
- Added receiver diagnostics exposure, one-second NibMac menu refresh, five-second info logging, and transport/session logs.
- Added iPad HUD brightness restore/dim behavior and app logging.
Manual checks: Not run (requires iPad, Accessibility permission, and Krita). Steps: draw for 30 s and read the NibMac menu line; run `log stream --predicate 'subsystem == "dev.yukai.nib"'`; three-finger tap to show the HUD at normal brightness, then tap again to dim.
Not done / risks: RTT and link diagnostics are measured on the existing main-actor delivery path; delivery timing and network parameters were intentionally left unchanged for task 0008.
```
