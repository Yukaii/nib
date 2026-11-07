---
id: "0008"
title: Smooth delivery — off-main receive and injection, no predicted traffic, jitter buffer
status: doing
milestone: M2
depends: ["0007"]
---

## Goal

The Mac cursor follows the Pencil smoothly with low, steady latency: no
receive backlog, no receiver-side loss, and samples replayed evenly.

## Context

Measured on hardware with 0007 (iPad mini 7, same Wi-Fi):
- RTT while drawing is 15–17 ms, so the network is fine.
- Rate is 190–440 Hz. That is above 240 Hz because predicted samples are
  sent, and the Mac then drops them.
- Loss is 0.6–11.6% and delay variation p95 is 110–150 ms.

The likely cause is in `PenLinkReceiver`: every UDP datagram hops to the
main actor via `Task { @MainActor }`, and `receiveMessage` is only re-armed
after decode, stats and CGEvent posting finish there. Packets queue up and
the socket buffer overflows. The arrival time is also taken on the main
actor, so the backlog shows up in the jitter stat.

1. **iPad:** stop sending `.predicted` samples (the Mac can never use them;
   keep them for the HUD trace only). Keep the triple-send of transitions.
2. **Mac receive off main:** UDP receive, decode, the host/sequence check,
   `LinkStats.record` and the arrival timestamp all happen on the network
   queue, and the next receive is re-armed immediately. Session/control
   state may stay on the main actor. The UDP gate needs a thread-safe view
   of "accepted host + sequencer" (a lock-protected struct is fine; explain
   its safety in a comment).
3. **Injection off main:** a dedicated serial `DispatchQueue` with
   `.userInteractive` QoS owns `PenInjectionController`. Display, surface
   and trust updates are sent to that queue. `CGEvent` creation and posting
   happen there.
4. **Jitter buffer:** `PlayoutScheduler` (NibCore, pure, tested) sits on
   the injection queue.
   - Offset = min(arrival − senderTimestamp) over a sliding 2 s window.
   - Each sample plays at senderTimestamp + offset + delay, with delay
     adaptive = p95 of (arrival − senderTimestamp − offset) over the
     window + 2 ms, clamped to 2…40 ms.
   - Never reorder. A late sample plays immediately.
   - Transitions (down/up/cancel/proximityExit) are never dropped.
   - After a gap > 100 ms in the stream (new stroke), re-anchor so the
     first sample is not held for stale reasons.
   - Drive it with a `DispatchSourceTimer` on the injection queue (1 ms
     leeway, only while samples are pending). In tests, use an injected
     clock and drive it by calling a `drain(now:)` function.
   - A NibMac menu toggle "Smoothing" (on by default), persisted, switches
     it to passthrough for A/B comparison.
5. **Network params:** UDP on both sides uses `serviceClass =
   .interactiveVoice`; TCP control sets `noDelay = true`. Do **not** enable
   peer-to-peer (AWDL) in this task.
6. **Stats:** add `inject p95 ms` (time from arrival to post) and the
   current playout delay to the 0007 menu line, e.g.
   `240 Hz · loss 0.0% · jitter p95 6 ms · delay 8 ms · inject p95 9 ms · RTT 16 ms`.

## Acceptance

- [ ] `PlayoutSchedulerTests`:
      - bursty arrivals (4 samples every 16.7 ms, sender timestamps 4.17 ms
        apart) come out ~4.17 ms apart;
      - order is preserved;
      - a late sample plays at once;
      - transitions are never dropped;
      - re-anchoring happens after a gap;
      - passthrough mode emits immediately;
      - the adaptive delay stays within its clamp.
- [ ] NibPad: test or code-level guarantee that `.predicted` samples
      never reach `PenLinkSender.send`.
- [ ] No `Task { @MainActor` (or any main-actor hop) remains on the
      per-datagram path in `PenLinkReceiver`, and none on the
      per-sample injection path in NibMac (reviewer checks the code).
- [ ] Manual checks in Handoff: draw 30 s with smoothing on and off and
      record both menu lines; expect rate ≈ 240 Hz, loss < 1%, jitter p95
      in the tens of ms at most, and a smoother cursor with smoothing on.
      Say whether you ran them.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- USB path, AWDL, pressure curves, hover tuning, wire-format changes.

## Handoff

Filled in by the worker:

```
Branch/commit: t3/smooth-delivery-threading @ f21153fe0b3cc3547c794a23d2f945fa326d5add
Verify: verify: ok (Test run with 48 tests; NibMac + NibPad built)
Done:
- Removed predicted samples from the sender hot path while retaining HUD trace data.
- Moved UDP decode, admission, sequencing, arrival timestamps, and stats recording off the main actor with lock-backed state; re-arms receive immediately.
- Added serial user-interactive injection worker, adaptive FIFO playout scheduler, persisted Smoothing toggle, and inject/playout diagnostics.
- Configured interactiveVoice UDP and noDelay TCP parameters on both peers; added deterministic scheduler coverage.
Manual checks: 30 s smoothing on/off drawing and menu-line comparison not run (requires iPad, Accessibility, and a drawing app).
Not done / risks: Hardware latency and loss targets remain to be validated manually; no USB/AWDL changes were made.
```
