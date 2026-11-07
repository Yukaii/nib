---
id: "0023"
title: Encrypted sessions — seal control frames and samples
status: todo
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
- [ ] The benchmark result is pasted in Handoff and is within budget.
- [ ] `scripts/verify.sh` passes. Manual checks written in Handoff (Krita
  pressure stroke over Wi-Fi and USB; `nib-receive` cannot read samples
  without the key). Say whether you ran them.

## Out of scope

- Changing pairing UX (0022). Several simultaneous iPads.

## Handoff

```
Branch/commit:
Verify:
Done:
Manual checks:
Not done / risks:
```
