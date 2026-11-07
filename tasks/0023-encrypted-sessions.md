---
id: "0023"
title: Encrypted sessions — seal control frames and samples
status: review
milestone: M3
depends: ["0022", "0024"]
---

## Goal

After `helloAck`, every control frame and every pen sample, over Wi-Fi and
USB, is sealed with ChaCha20-Poly1305 under per-session, per-direction keys
derived from the pairing key. Pressure still reaches Krita with no noticeable
latency change.

## Context

- Read `docs/decisions/0011-pairing-and-encryption.md` (Sessions) and the
  Pairing section of `docs/protocol.md` that task 0022 adds. Protocol rules
  in AGENTS.md apply: spec + vectors in the same commit.
- Keys: `HKDF-SHA256(ikm: pairKey, salt: iPadNonce ‖ hostNonce, info:
  "nib-session ipad→host" / "nib-session host→ipad", 32 bytes)`.
- **Control frames** (TCP and the USB 0x01 frames): after `helloAck`, the
  body of each length-prefixed frame is `counter (8 bytes LE) ‖ ciphertext ‖
  tag`. The counter starts at 0 per direction and must strictly increase. The
  AEAD nonce is the 12-byte `0x00000000 ‖ counter`. A gap or a replay closes
  the session.
- **Samples**: the UDP datagram (and the USB 0x02 frame) becomes `sequence
  (4 bytes LE, plaintext) ‖ sealed 40-byte PenSample ‖ tag`. The nonce is
  derived from the 32-bit sequence plus an 8-byte per-session epoch, so a
  wrap can't reuse a nonce. Define the epoch in the spec and rekey before the
  wrap. Sequence ordering and triple-send stay as they are; a datagram that
  fails to open is dropped and counted in `LinkStats` loss.
- Put the sealing in NibCore (`Pairing/` or `Transport/Session/`) as pure
  functions with CryptoKit. The framers stay byte-level, and a session layer
  wraps them, so `ControlFramer`/`StreamFramer` keep their current tests.
- Performance: sealing must happen on the existing send path without main
  thread hops. Measure it: add a test or a `nib-receive`-style benchmark
  printing µs per seal/open for 10k samples. The budget is < 20 µs each on
  Apple Silicon.

## Acceptance

- [ ] Tests: seal/open round-trip for both directions; tampered ciphertext,
  tag or counter → rejected; replayed counter → rejected; sample nonce never
  repeats across a sequence wrap (test with the sequence near 2³²).
- [ ] `protocol/vectors/session.json` (fixed pairKey + nonces → keys; one
  sealed control frame; one sealed sample) checked by `ProtocolVectorTests`.
  `docs/protocol.md` describes the sealed layouts byte by byte.
- [ ] Replay (0022 review): session keys use the fresh host nonce, so a
  replayed `hello` gets a session in which no frame or sample opens. Test it
  end to end through `PenLinkReceiver` handling, not only the pure functions.
  Until this lands, 0022 authenticates only the start of a connection.
- [ ] The benchmark result is pasted in Handoff and is within budget.
- [ ] `scripts/verify.sh` passes. Manual checks written in Handoff (Krita
  pressure stroke over Wi-Fi and USB; `nib-receive` cannot read samples
  without the key). Say whether you ran them.

## Out of scope

- Changing pairing UX (0022). Several simultaneous iPads.

## Handoff

```
Branch/commit: t3/encrypted-session-integration-fixes @ 68a7ba530fbdcdc29cc0400a372bcbfc4146efc2
Verify: verify: ok (Test run with 169 tests; NibMac + NibPad built)
Done:
- Switched the TCP and USB dispatchers atomically from plaintext helloAck to sealed frames, including bytes buffered in the same read; covered split and combined Wi-Fi/USB dispatcher tests.
- Replaced mutable SessionCipher value state with lock-protected directional counters and separate control/sample HKDF subkeys; added concurrent counter, replay, tamper, and nonce uniqueness coverage.
- Enforced sample sealing rules (no predicted samples, identical triple-send re-seal only, strictly newer sequence, clean sequence-wrap failure) and made paired-session setup fail closed.
- Added production HostLink replay coverage with fresh host nonces and isolated ciphers; updated protocol documentation and session vector for the new UTF-8 HKDF info strings and plaintext helloAck boundary.
- Release benchmark: `session sample seal benchmark: 2.21 µs per seal (10k)`; `session sample open benchmark: 1.66 µs per open (10k)`.
Manual checks: Not run. On an iPad mini 7 and Apple Silicon Mac, pair from a clean install, draw a pressure stroke in Krita over Wi-Fi, confirm pressure and front-app updates, disconnect/reconnect, then repeat over USB. During both sessions verify the iPad screen stays black and pressure varies in Krita. Launch an unkeyed `nib-receive` and confirm it cannot decode the sealed samples.
Not done / risks: Physical iPad/Mac/Krita checks require hardware and were not run. Existing Swift concurrency warnings in Network callback code remain; no new main-actor hop was added to the Pencil sample path.
```
