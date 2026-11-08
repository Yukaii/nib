---
id: "0026"
title: Pairing over USB — USB wins over Wi-Fi before sign-in too
status: review
milestone: M3
depends: ["0025"]
---

## Goal

With the USB-C cable plugged in (Wi-Fi on or off), tapping Pair on the iPad
shows the same 6-digit code on both screens and pairing completes over USB.
Wi-Fi never displaces a USB connection, before or after sign-in.

## Context

Found on device (2026-11-08): the pairing code appeared only after unplugging
the cable. Code reading in `Packages/NibCore/Sources/NibCore/Transport/PenLink.swift`:

- `PenLinkReceiver.acceptConnection` (Wi-Fi, ~1017): while no session is
  signed in and no pairing machine is active, a new Wi-Fi connection
  **replaces** the current one, even when that is the USB link. The iPad's
  Wi-Fi sender retries every ~2 s, so it keeps evicting the USB pairing-only
  connection. `acceptUSBConnection` (~928) then sees `.none` and evicts Wi-Fi.
  They ping-pong, and the user never gets a stable link to pair on.
- When Wi-Fi replaces a USB connection, `usbMode`/`usbConnection`/
  `usbDispatcher` are not reset, so later `sendControl` can go to the dead USB
  link.
- The iPad (`Apps/NibPad/NibPadApp.swift` `NetworkSink.beginPairing/
  confirmPairing/cancelPairing/pairAgain`) drives pairing on **both**
  transports at once, and both report events into one UI.
- Signed-in sessions already prefer USB (decision 0005,
  `USBTransportArbitration`). Apply the same preference to pre-sign-in
  (pairing-only and pending-hello) connections.

Changes:

1. Host: one arbitration rule for every connection state. A USB connection is
   never displaced by Wi-Fi; a Wi-Fi newcomer while USB is present (in any
   state) gets `busy` and is closed. USB may replace a Wi-Fi connection that
   is not mid-pairing; an active pairing machine is still never displaced
   (the 0022 rule). Put the decision in `USBTransportArbitration` (pure,
   tested) and use it in both accept paths.
2. Host: any replacement fully resets transport state (`usbMode`,
   `usbConnection`, dispatchers, gates) so replies always go to the live link.
3. iPad: pairing actions go to **one** transport. Use USB when the USB
   listener has a live connection (including pairing-only), otherwise Wi-Fi.
   Pairing events from the non-active transport are ignored. Optionally the
   Wi-Fi sender backs off while USB has a connection.
4. Logging (no keys, nonces, proofs or codes): host and iPad log connection
   accept/replace/busy/close with transport and reason, and pairing phase
   changes. This makes the next device bug diagnosable from
   `/usr/bin/log show` on the Mac.

## Acceptance

- [ ] Tests for the arbitration decision table: {none, Wi-Fi pending,
  Wi-Fi pairing-only idle, Wi-Fi pairing active, Wi-Fi session, USB pending,
  USB pairing-only, USB session} × {Wi-Fi, USB newcomer}.
- [ ] Test: Wi-Fi hellos every 2 s during a USB pairing-only phase never
  replace the USB link, and pairing completes over USB (drive the host
  policy with real framer bytes, as in `PairingTests`).
- [ ] Test: the iPad picks the USB transport for pairing when both are up.
- [ ] `scripts/verify.sh` passes.
- [ ] Manual checks (user, via `scripts/install-devices.sh both`): pair with
  cable + Wi-Fi on; pair with cable + Wi-Fi off; unplug mid-session → falls
  back to Wi-Fi; plug back in → USB again, no re-pair.

## Out of scope

- Encrypted sessions (0023).

## Handoff

```
Branch/commit: t3/usb-pairing-arbitration @ 59724df895db4ed090232884b2f77b9367fb5f43
Verify: verify: ok (Test run with 168 tests; NibMac + NibPad built)
Done:
- Added a pure eight-state USB/Wi-Fi arbitration table and routed both Mac accept paths through it.
- USB pairing-only links now reject Wi-Fi newcomers; replacements clear all link state before installing the live transport.
- iPad pairing chooses one transport, preferring any live USB stream, and ignores events from the other transport.
- Added transport and pairing-phase diagnostics without secrets, plus framer-backed policy tests.
Manual checks: not run. User steps: run `scripts/install-devices.sh both`; with Wi-Fi on, connect the cable and tap Pair on the iPad, confirm the same code on both screens; repeat with Wi-Fi off; during a session unplug the cable and verify Wi-Fi resumes, then reconnect the cable and verify USB resumes without pairing again.
Not done / risks: On-device checks require the user's paired iPad, Mac Accessibility permission, and taps; pressure sample handling was left unchanged.
```
