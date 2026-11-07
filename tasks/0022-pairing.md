---
id: "0022"
title: Pairing by numeric comparison, stored keys, authenticated hello
status: review
milestone: M3
depends: ["0021"]
---

## Goal

An iPad must pair with a Mac once before it can control it. Pairing shows the
same 6-digit code on both screens, and the user confirms on both. After that,
every `hello` proves possession of the pairing key. The Mac's "Remember"
checkbox and the device-ID allow list go away.

## Context

- Read `docs/decisions/0011-pairing-and-encryption.md` (pairing and the
  session-key part) and `docs/protocol.md` (protocol rules in AGENTS.md:
  spec + vectors change in the same commit).
- **This task is pairing plus authentication only.** Sealing every frame and
  sample (AEAD) is task 0023. Here, `hello` carries `nonce` and
  `proof = HMAC-SHA256(pairKey, "nib-hello" ‖ deviceID ‖ nonce)`, and
  `helloAck` carries the host nonce and a host proof. Each side verifies the
  other's proof. Mismatch → `helloAck { accepted: false, reason }` with a
  next step ("Pair again").
- New control messages: `pairRequest { deviceID, deviceName, publicKey, nonce }`,
  `pairResponse { hostID, hostName, publicKey, nonce }`,
  `pairResult { accepted, reason? }`. Keys and nonces are base64 strings.
  - Code = `SHA256("nib-pair" ‖ transcript)` → first 4 bytes, big-endian,
    mod 10⁶, zero-padded to 6 digits.
  - The transcript is the concatenation of both public keys and both nonces,
    in a fixed order. Pin the exact order in the spec.
  - `pairKey = HKDF-SHA256(ikm: X25519 shared secret, salt: transcript hash,
    info: "nib-pair-key", 32 bytes)`.
- Pure crypto and state machine in NibCore (`Pairing/`), using CryptoKit only:
  code derivation, key derivation, proof make/verify, and the pairing state
  machine for both roles. Key storage behind a protocol, with a Keychain
  implementation in the apps and an in-memory one in tests.
- `hostID`: a stable UUID generated once by NibMac and stored in its defaults.
- Mac UI: the accept prompt becomes "Pair with <iPad>? Code 123 456"
  [Pair] [Cancel]. A **Paired iPads** submenu lists them with Forget.
  Migration: existing `acceptedDevice.*` defaults are deleted, so everyone
  pairs once.
- iPad UI: the onboarding "Choose your Mac" step continues into "Check that
  your Mac shows 123 456" [Pair] [Cancel]. The companion panel gets
  "Forget this Mac". A rejected proof leads to re-pairing, with no dead end.
- USB uses the same flow (control frames over the USB stream).

## Acceptance

- [ ] Tests with fixed keys/nonces: code derivation, pairKey derivation, and
  proof verify; a tampered public key or nonce changes the code; a wrong
  pairKey fails the proof.
- [ ] Test: the pairing state machine on both roles. Happy path, cancel on
  either side, and a timeout leave no stored key.
- [ ] Test: the receiver session rejects a hello with a missing or bad proof
  and accepts a valid one.
- [ ] `docs/protocol.md` gains a Pairing section, and `protocol/vectors/`
  gains a `pairing.json` (fixed X25519 private keys → public keys, code,
  pairKey, proofs), checked by `ProtocolVectorTests`.
- [ ] (Moved to 0024: retiring `acceptedDevice.`; Apps/ stay unchanged here.)
- [ ] `scripts/verify.sh` passes. Manual checks are written in Handoff
  (pair over Wi-Fi, forget on either side, re-pair, pair over USB). Say
  whether you ran them.

## Out of scope

- Encrypting frames and samples (task 0023).
- Several simultaneous iPads.

## Handoff

```
Branch/commit: t3/pairing-transport-hardening @ 1fba800
Verify: verify: ok (Test run with 156 tests; NibMac + NibPad built)
Done:
- First pairing remains reachable: unpaired hello gets
  helloAck{pairingRequired:true} and stays open in pairing-only state on Wi-Fi
  and USB; only hello/pair*/ping are accepted.
- Active pairing machines hold their connection through the 60 s timeout;
  newcomers receive busy and count against the attempt limiter. Idle invites
  close after 10 s and may be replaced.
- Pairing ownership uses monotonically increasing connection generations, with
  explicit HostLink/DeviceLink/PairingDriver reset on replacement and loss.
- Attempt-limit refusals use an unbound, generation-targeted send callback, so
  the requesting connection receives pairResult{accepted:false}.
- Device-side pairingRequired hints never publish unauthenticated host info or
  delete a stored key; Wi-Fi and USB ignore probe/frontApp and all other
  non-pairing messages in pairing-only state.
- Extracted ControlLinkDispatcher and StreamLinkDispatcher run the production
  ControlFramer/StreamFramer receive/dispatch paths against byte transports.
- Existing commit-reveal, proof, authenticated hello, cancellation, timeout,
  and protocol vector coverage remains intact.
- fail() now sets phase=.failed and clears pending; invalid reveal leaves no
  secrets and terminal phase (tested).
- Identities bound: deviceID in commitment, deviceID+hostID length-prefixed in
  transcript (fixed order 2-byte BE len). Relay cannot relabel. Spec + vectors.
- pairing.json self-contained: deviceID/hostID, distinct hello nonces, expected
  proofs, negative vectors (wrong reveal, tampered transcript, wrong key).
  Generated from code.
- Prefix-free labels nib-hello/nib-ack/nib-commit/nib-pair-code/nib-pair-key;
  both proof verifiers require exactly 32-byte nonces. Spec states it.
- Removed dead ReceiverSession.hello(_:busy:now:) overload; production routes
  through HostLink/DeviceLink + protocolVersion overload. Tests exercise it.
- DeviceLink orders verification before trust: onHostInfo + rejection reason
  only after proof when a key is held; unauthenticated rejections shown but
  never delete a key. Same in PenLinkSender and UsbLinkListener.
- Removed _ = pairingStore and dead isTerminal blocks; triplicated
  pairing/timeout driving moved into shared PairingDriver used by receiver,
  sender and USB listener.
- Host attempt limiting: 3 failures in 5 min → refuse pairRequests 60 s with
  readable reason. Injected clock, tested.
- Apps/NibMac/NibMacApp.swift identical to main. No keys/nonces/proofs/codes
  logged.
Manual checks: fresh pair over Wi-Fi; reconnect; Forget either side → re-pair;
  pair over USB with Wi-Fi off; Cancel either side leaves no stored key;
  NOT RUN (NibCore only, no app UI in this task; deterministic framer and
  HostLink/DeviceLink tests cover the production dispatch paths).
Not done / risks:
- App UI + KeychainPairingKeyStore live in 0024 (Mac prompt/submenu, iPad
  code step, Forget buttons, hostID minting, allow-list migration).
- Single-key sender verification assumes one paired host; SenderSession per
  known host will be needed if 0024 pairs several Macs.
- No live-network pairing exercised; only in-memory + framer + link unit
  tests. Recommend a Wi-Fi + USB manual pair in 0024.
```

