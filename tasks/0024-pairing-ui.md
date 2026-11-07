---
id: "0024"
title: Pairing UI on Mac and iPad, Keychain keys, retire the allow list
status: review
milestone: M3
depends: ["0022"]
---

## Goal

A user pairs an iPad with a Mac by comparing a 6-digit code on both screens,
over Wi-Fi or USB, and never sees the old Allow/Remember prompt again. Paired
devices reconnect silently, and either side can forget the other.

## Context

- 0022 delivers the NibCore pieces: `PairingCrypto`, the commit-reveal
  `PairingStateMachine`, proofs, the `PairingKeyStore` protocol, and pairing
  message handling in `PenLinkSender`/`PenLinkReceiver`/USB. This task wires
  them into the apps. Read decision 0011 and the Pairing section of
  `docs/protocol.md`.
- **Keychain**: a `KeychainPairingKeyStore` (Security framework, generic
  password, service `dev.yukai.nib.pairing`, account = peer ID,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), shared by both apps
  (NibCore, `#if canImport(Security)`). It has no unit test, since tests must be
  deterministic; cover it with a manual check.
- **Mac**: the receiver uses the Keychain store and `hostID`. An unpaired
  iPad's `pairRequest` shows a window or alert: "Pair with <iPad>? Make sure
  the iPad shows 123 456" [Pair] [Cancel], activated in front like today's
  prompt. A verified proof connects with no prompt. Add a **Paired iPads**
  submenu with Forget. On first launch of this version, delete
  `acceptedDevice.*` defaults and remove the Remember checkbox and the
  Allow/Deny prompt.
- **iPad**: the onboarding "Choose your Mac" step continues into a pairing
  step: "Check that your Mac shows 123 456" [Pair] [Cancel]. It handles a
  timeout, a cancel on the Mac, and "Pair again" after a rejected proof. The
  companion panel gets **Forget this Mac**. The status overlay shows "Pair with
  <Mac> to start" when needed.
- USB: the same screens. No special case for the cable (user decision).
- Follow AGENTS.md "Product quality bar": every failure has a next step.

## Acceptance

- [ ] `grep -rn "acceptedDevice\|Remember" Apps/NibMac` finds only the
  one-time cleanup.
- [ ] NibCore tests (with the in-memory store) for the app-facing glue added
  here, if any. `scripts/verify.sh` passes.
- [ ] Manual checks written in Handoff, and whether you ran them: fresh pair
  over Wi-Fi; reconnect without prompt after relaunching both apps; Forget on
  the Mac → iPad asks to pair again; Forget on the iPad → same; pair over USB
  with Wi-Fi off; Cancel on either side leaves nothing stored (Keychain Access
  shows no `dev.yukai.nib.pairing` item).

## Out of scope

- Encryption of frames and samples (0023).

## Handoff

```
Branch/commit: main @ e3ff5aa
Verify: verify: ok (Test run with 158 tests; NibMac + NibPad built)
Done:
- Added the shared KeychainPairingKeyStore with the required service, account, and accessibility policy.
- Wired persistent pairing stores and stable IDs into the Mac receiver and iPad Wi-Fi/USB links.
- Replaced the Mac allow/remember prompt with numeric pairing confirmation, paired iPad management, and Forget.
- Added iPad pairing, cancel/timeout/failure messaging, Pair again, and Forget this Mac controls.
Manual checks: not run (requires the user's iPad mini 7, Apple Pencil Pro, and Apple Silicon Mac).
  1. On a fresh install, launch Nib on both devices over Wi-Fi. On the iPad choose the Mac, tap Pair, and confirm the same six-digit code on both screens. Draw a pressure stroke in Krita.
  2. Quit and relaunch both apps. Confirm the iPad reconnects without a pairing prompt and pressure still reaches Krita.
  3. On the Mac menu open Paired iPads, choose Forget for the iPad, reconnect it, and confirm the iPad asks to pair again.
  4. On the iPad Companion panel choose Forget this Mac, reconnect, and confirm both screens ask to pair again.
  5. Turn Wi-Fi off, connect the USB-C cable, and repeat pairing and a pressure stroke. Repeat cancellation on either side and confirm no key is stored; verify Keychain Access has no dev.yukai.nib.pairing item.
Not done / risks: Keychain behavior and Wi-Fi/USB pairing need the manual hardware checks above. 
```
