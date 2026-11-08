---
id: "0027"
title: Transport tidy-up — USB arming race, Wi-Fi backoff on cable, log nits
status: review
milestone: M3
depends: ["0023"]
---

## Goal

USB sessions never drop because sealed bytes beat the Mac's arm step. The
iPad stops knocking on Wi-Fi while the cable is connected. Logs say exactly
what happened, once.

## Context

Follow-ups from the 0023 round-4 review (all fail-closed today, none a
downgrade). Paths are in `Packages/NibCore/Sources/NibCore/Transport/`.

1. **Mac USB arming race** (`PenLink.swift`, `handle(.hello)` →
   `sendControl(helloAck)` then `configureSession`; `receiveUSB` on the NW
   queue). Sealed bytes from the iPad can arrive before `configureSession`
   runs on main. They are then parsed as plaintext and the session closes
   (a rare drop under main-thread load). Send the plaintext ack and install
   the cipher in one dispatcher critical section. Capture the dispatcher per
   connection in `receiveUSB` instead of reading `usbDispatcher` off the main
   actor.
2. **Wi-Fi backoff while USB is up** (iPad, `Apps/NibPad/NibPadApp.swift` +
   `PenLinkSender`). With the cable in, the Wi-Fi sender retries every 1-2 s
   and gets `busy`, which floods the Mac log. Pause Wi-Fi connects while the
   USB listener has a live connection, and resume within ~2 s of unplugging.
   The plug/unplug switch the user confirmed must stay seamless.
3. **Logs**:
   - `session accepted from <deviceName>` logs a peer string as public and
     unbounded; make it private and truncate it to 64 chars.
   - `disconnectSession` logs `reason=ended` even with nothing open.
   - Dispatcher failures are logged twice (dispatcher `onCloseReason` and the
     owner); log once.
   - After a sequence wrap, USB logs/closes once per sample.
4. `.busy` in host `handle(.hello)` sets `connection = nil` without
   `disconnectSession`, leaving gates up until the heartbeat times out. Only a
   key-holding peer can reach it, but tear down properly.

5. **First session after a NibMac relaunch dies once** with
   `session close … reason=heartbeat-timeout` 3 s after `session accepted`,
   then the next session holds (seen twice on device, 10:06 and 10:17 on
   2026-11-08, Wi-Fi and USB). Likely the iPad keeps heartbeating its old,
   dead connection or races two connects. Find out from the code and the
   iPad log (the user can collect one), and fix it so a relaunch reconnects
   once.

## Acceptance

- [x] Test: on the Mac USB path, sealed bytes delivered immediately after the
  ack (before main runs) open correctly (drive the dispatcher directly).
- [x] Test: the Wi-Fi sender pause/resume decision (pure helper) for cable
  in / cable out / cable out → in.
- [x] Test or log evidence that a host restart yields exactly one reconnect.
- [x] `scripts/verify.sh` passes.
- [ ] Manual (user, `scripts/install-devices.sh both`): Mac log quiet with the
  cable in; unplug → Wi-Fi within ~2 s; replug → USB; pressure in Krita.

## Out of scope

- Protocol changes; spec and vectors stay as they are.

## Handoff

```
Branch/commit: t3/transport-tidy @ 60d4bfacc56f452bfdcb2e241169798c03d1c98a
Verify: verify: ok (Test run with 187 tests; NibMac + NibPad built)
Done:
- Mac USB sends the plaintext hello acknowledgement and arms the stream cipher under one dispatcher lock; receiveUSB retains the per-connection dispatcher so immediate sealed bytes are decoded safely.
- iPad pauses Wi-Fi browsing, reconnects, and retry timers for any live USB stream, including pairing-only; unplug resumes Bonjour discovery immediately.
- Host restart reconnect scheduling is single-flight, and branch logs identify USB preference, paused/reconnect decisions, busy teardown, and sequence-wrap teardown without secrets.
- Session peer names are private and capped at 64 characters; empty disconnects and duplicate dispatcher close notifications no longer create session-close log noise.
- Added deterministic dispatcher, cable transition, and single-reconnect policy tests.
Manual checks: Not run. User should run `scripts/install-devices.sh both`, confirm no Wi-Fi busy spam while cabled, unplug and verify Wi-Fi within ~2 seconds, replug and verify USB, then draw pressure strokes in Krita.
Not done / risks: Physical iPad/Mac cable switching and relaunch behavior still require the user's device check; no protocol files changed.
```
