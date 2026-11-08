---
id: "0025"
title: Re-pairing after Forget works from either side
status: doing
milestone: M3
depends: ["0024"]
---

## Goal

After **Forget** on the iPad, on the Mac, or both, tapping **Pair** on the
iPad shows the same 6-digit code on both screens and pairing completes, over
Wi-Fi and USB. No state leaves the user without a working next step.

## Context

Found on device (iPad mini 7 + Mac, 2026-11-08): after Forget, tapping Pair
showed no code on either screen. Code reading (`Packages/NibCore/Sources/NibCore/Transport/PenLink.swift`,
`Pairing/HostDeviceLink.swift`, `Apps/NibPad/NibPadApp.swift`):

1. **iPad "Forget this Mac"** (`NetworkSink.forgetMac` → `PenLinkSender.pairAgain`)
   deletes the key, then sends `pairRequest` over the **live authenticated
   session**. The host ignores pairing traffic on an established session
   (`handlePairingMessage`: `if hostLink.sessionConnected { return }`), so
   nothing happens. Fix: Forget/Pair-again ends the current connection and
   reconnects, so pairing runs on a fresh pairing-only connection.
2. **Host still holds a key, iPad does not** (iPad forgot, or reinstalled):
   `HostLink.receiveHello` rejects a proof-less hello from a known device
   with "Pair again" and disconnects, a dead end. Change: a hello **without**
   `nonce`/`proof` from a device the host has a key for gets `pairingRequired`
   (pairing-only state), exactly like an unknown device. The old key is kept
   until the new pairing completes, then replaced. A hello **with** an invalid
   proof is still rejected. Security is unchanged: pairing still needs both
   users to confirm the code, and the prompt rate limit applies (decision 0011).
3. **iPad "rejected / Pair again" states** (`connectionLost(reconnect: false)`)
   must never strand the user. The Pair button on the sheet, onboarding and
   status screen starts a fresh connection plus pairing whatever the current
   link state is.
4. The protocol behaviour in (2) is a spec change: update `docs/protocol.md`
   Pairing section; vectors only if bytes change.

## Acceptance

- [ ] End-to-end tests through `HostLink`/`DeviceLink`/`PairingDriver` with
  real framer bytes: (a) iPad forgets → re-pair succeeds; (b) Mac forgets →
  re-pair succeeds; (c) both forget → re-pair succeeds; (d) iPad keeps a
  stale key while the Mac forgot → untrusted hint → Pair → succeeds; (e) a
  hello with a wrong proof is still rejected; (f) a known device's proof-less
  hello does not delete or replace the host key unless pairing completes.
- [ ] `scripts/verify.sh` passes.
- [ ] Manual checks in Handoff, run by the user with
  `scripts/install-devices.sh both`: each of (a)–(d) on device over Wi-Fi,
  plus (a) over USB.

## Out of scope

- Encrypted sessions (0023, reopened). This task builds on main without them.

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks:
Not done / risks:
```
