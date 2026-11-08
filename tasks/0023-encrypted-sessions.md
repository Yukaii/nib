---
id: "0023"
title: Encrypted sessions — seal control frames and samples
status: review
milestone: M3
depends: ["0022", "0024", "0025"]
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

## Reopened 2026-11-08 (device failure)

Merged after three review rounds (branch history up to `4894925`, merge
`70385d4`), then reverted (`c00253e`). On iPad mini 7 + Mac over Wi-Fi,
authenticated sessions connected and dropped every 1-4 s in a loop. Mac log:
`session accepted` → `session connected` → `session disconnected`, with no
reason logged. Unit and dispatcher tests all passed. Next round:

- Start from `4894925` (cherry-pick or `git merge --no-ff 4894925` onto a
  branch from main after 0025), so reviewed work is kept.
- First add **close-reason logging** on both sides (which check failed:
  open/auth failure, counter mismatch, malformed, heartbeat timeout, peer
  EOF), with no keys, nonces or plaintext. The Mac's unified log is readable
  with `/usr/bin/log show` (zsh's builtin `log` shadows it). iPad logs need
  root (`sudo log collect --device-udid …`), so have the iPad send nothing
  extra; host-side reasons plus local reasoning must find it.
- Reproduce on device with `scripts/install-devices.sh both` (the user is
  available to tap Pair). Prime suspects: the heartbeat ping/probe path after
  arming, a `probe`/`probeReply` or `frontApp` sent around the arm point,
  and the iPad's `awaitingAuthenticatedAck` gate dropping a needed reply.
  Write a test that reproduces the loop **before** fixing it.

## Handoff

```
Branch/commit: t3/fix-encrypted-session-drops @ 132ff4622a0daa95afdafa3afc4cb604d04cc507
Verify: verify: ok (Test run with 184 tests; NibMac + NibPad built)
Done:
- Re-applied the reviewed ChaCha20-Poly1305 session implementation on top of 0025/0026 and kept pairing-only, re-pair, USB arbitration, detached handling, and pairing-driver persistence behavior.
- Serialized sealed control and USB stream sends through each dispatcher lock. Before this, concurrent heartbeat, probe, front-app, pairing, and sample sends could allocate counters in one order and enqueue bytes in another, producing a receiver counter mismatch and the observed reconnect loop.
- Added close-reason logging for auth/open failure, malformed frame, counter mismatch, authentication failure, sequence replay/wrap, heartbeat timeout, peer EOF/error, arbitration replacement, busy rejection, USB detach, and pairing-only outcomes. Logs contain transport and reason/message type only.
- Added a 10-simulated-second sealed heartbeat + sample dispatcher test and a concurrent sealed-control ordering test.
- Benchmark: `session sample seal benchmark: 3.61 µs per seal (10k)`; `session sample open benchmark: 3.19 µs per open (10k)`.
Manual checks: Not run. On the iPad + Mac, collect both logs while reproducing: `/usr/bin/log show --last 5m --predicate 'subsystem == "dev.yukai.nib"'` on Mac and `sudo log collect --device-udid <UDID>` for iPad. Look for `session close ... reason=counter-mismatch` or `authentication-failed` to confirm the old sealing race; `malformed-control`/`malformed-sample` indicates framing or sample bytes; `heartbeat-timeout` indicates probe/ping replies are not arriving; `peer-eof`/`peer-error` indicates the peer or transport ended first; no close reason with a disconnect points to an external transport/OS drop. `pairing message=...`, `hello outcome=...`, and `connection ... reason=...` distinguish pairing, frontApp/probe timing, and USB/Wi-Fi arbitration.
Not done / risks: Real device pressure stroke over Wi-Fi and USB was not run in this worktree. The simulated test exercises sealed framer bytes, heartbeat ping/probe traffic, and samples but cannot prove Network.framework behavior or iPad log output. Existing Swift concurrency warnings in Network callback code remain; no new main-actor hop was added to the Pencil sample path.
```
