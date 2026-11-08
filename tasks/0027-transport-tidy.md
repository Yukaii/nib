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
Branch/commit: t3/transport-tidy-fixes @ b37da425941ee8041bf307ca5f967956b69d1e2c
Verify: verify: ok (Test run with 189 tests; NibMac + NibPad built)
Done:
- USB pause is emitted only after an accepted `.pairingRequired` or `.connected` hello acknowledgement; rejected or busy USB attempts leave active Wi-Fi pairing untouched.
- Pairing connection loss emits a user-visible failure, and every live USB link has a 10-second pending/pairing watchdog that resumes Wi-Fi after a silent cable pull.
- The host USB dispatcher is tested decoding sealed bytes immediately after arming; stale sender callbacks and duplicate USB close handling are guarded.
- Peer names in Mac logs are private and capped at 64 characters; sequence-wrap cleanup remains off the per-sample path.
- No protocol files or vectors changed.
Manual checks (not run):
1. Run `scripts/install-devices.sh both` with an iPad mini 7 and Mac, unlock both devices, and start NibPad and NibMac from the on-screen instructions.
2. Pair over Wi-Fi, start an active pairing flow, then plug in the USB-C cable. Confirm the Wi-Fi pairing UI remains active while USB retries report busy; confirm Wi-Fi does not pause until USB is accepted.
3. Complete USB pairing/session setup and draw pressure strokes in Krita. Leave the cable connected and idle for one minute; confirm the session remains connected and the Mac log has no Wi-Fi busy spam.
4. Pull the cable during USB pairing before authentication completes. Confirm Wi-Fi resumes within about 10 seconds and the pairing UI shows a next step after the lost connection.
5. With a connected USB session, unplug and confirm Wi-Fi reconnects within about 2 seconds; replug and confirm USB becomes active again without stopping the pressure stroke path.
6. Relaunch NibMac while the iPad is paired, wait for the first reconnect, and draw immediately. Confirm there is no one-time heartbeat timeout; repeat once after leaving the cable connected for an idle minute.
Not done / risks: Physical iPad/Mac cable switching, watchdog timing, and relaunch behavior still require the device check.
```
