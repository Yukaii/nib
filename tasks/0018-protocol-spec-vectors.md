---
id: "0018"
title: Language-neutral protocol spec and golden test vectors
status: review
milestone: M3
depends: ["0016", "0017"]
---

## Goal

`docs/protocol.md` fully describes protocol v2, in enough detail that someone
can write a host in another language (Rust, M5) without reading Swift.
`protocol/vectors/` holds golden examples, and a Swift test proves the code
and the vectors agree.

## Context

- Sources of truth to describe: decisions 0002 (sample packet), 0004
  (discovery, TCP framing, UDP), 0005 (USB: usbmuxd port, 0x01/0x02 frames),
  0006 (keys, frontApp), 0008 (v2 rules); code in `PenSample*.swift`,
  `Transport/ControlMessage.swift`, `Transport/Gesture.swift`,
  `Transport/USB/StreamFramer.swift`, `Settings/KeyNames.swift`.
- `docs/protocol.md` sections:
  1. Overview and versions
  2. Discovery (Bonjour type, TXT if any)
  3. Session (hello → helloAck, ping/timeout timings, probe/RTT, triple-send
     of transitions)
  4. Control framing (TCP and USB)
  5. Every control message with a JSON example and field table
  6. Gesture and key semantics, including the W3C key list and modifier
     mapping per platform
  7. Capabilities
  8. Sample packet byte table
  9. Compatibility rules
  
  Keep it under 400 lines. Write for implementers: say what a receiver MUST do
  with bad input.
- `protocol/vectors/` (repo root, not inside the Swift package, so Rust can
  read it):
  - `control.json`: list of `{ name, json, framedHex }`. One entry per message
    type and per gesture case, plus a modifier-only key chord.
  - `samples.json`: list of `{ name, hex, fields }` for each `kind`, eraser,
    predicted, and sequence wrap.
  - `invalid.json`: list of `{ name, hex, transport: tcp|udp|usb, error }`
    covering bad magic, bad version, wrong length, NaN pressure, out-of-range
    x, oversized frame, and an unknown control type (expected outcome: ignored,
    not an error).
  - `keys.json`: W3C code → display name → macOS `kVK_*`.
- Test `ProtocolVectorTests` reads the files through a path relative to
  `#filePath`. Every valid vector must decode to its fields and re-encode
  byte-for-byte. Every invalid vector must fail as stated. `keys.json` must
  equal `KeyNames` + the macOS table.
- Comparing JSON byte-for-byte is fragile (key order). Compare decoded values
  for `json`, and compare bytes only for `framedHex`, produced with sorted keys.
  If the framer doesn't sort keys today, make it do so
  (`.sortedKeys`); that is the one code change allowed here.

## Acceptance

- [ ] `docs/protocol.md` exists, has the nine sections, and has no Swift type
  names in normative text (field names on the wire are fine).
- [ ] `swift test --package-path Packages/NibCore --filter ProtocolVectorTests`
  passes. Corrupting one hex digit in `samples.json` makes it fail (check by
  hand, then revert).
- [ ] Every `ControlMessage` and `Gesture` case appears in `control.json`, and
  a test enforces this (e.g. a count over the enum's cases).
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Any protocol behaviour change other than sorted-keys encoding.
- Rust code.

## Handoff

```
Branch/commit: t3/protocol-spec-vectors @ a31c54a3fe0b4108bdb07087b288d0b0dd561db5
Verify: verify: ok (Test run with 126 tests; NibMac + NibPad built)
Done:
- Added the language-neutral v2 protocol specification with discovery, session, framing, controls, gestures, capabilities, samples, and compatibility rules.
- Added control, sample, invalid-input, and W3C key translation vectors.
- Added `ProtocolVectorTests` covering decoding, byte-for-byte re-encoding, invalid outcomes, and complete control/gesture case coverage.
- Enabled sorted JSON object keys for deterministic control framing.
Manual checks: Corrupted one sample vector hex digit; `swift test --package-path Packages/NibCore --filter sampleVectorsRoundTrip` failed, then restored the vector. Hardware/iPad/Krita checks not run.
Not done / risks: The implementation intentionally differs from decision 0008 in three documented ways: `ControlFramer` skips unknown control `type`s and unknown gesture `type`s; `frontApp` decodes the legacy `bundleID` key; and the version-mismatch reason comes from `ReceiverSession.versionMismatchReason`.
```
