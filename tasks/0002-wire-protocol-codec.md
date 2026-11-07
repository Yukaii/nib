---
id: "0002"
title: Wire protocol codec for PenSample
status: doing
milestone: M1
depends: []
---

## Goal

`PenSample` encodes to and decodes from the exact 40-byte layout in
`docs/decisions/0002-wire-protocol.md`, with strict validation and a
wrap-aware sequence comparison.

## Context

- Type: `Packages/NibCore/Sources/NibCore/PenSample.swift` (already defines
  fields, `magic`, `version`, `byteCount`). Do not change field names or the
  layout.
- Add `Packages/NibCore/Sources/NibCore/PenSampleCodec.swift` with:
  - `extension PenSample { func encode() -> [UInt8] }` (exactly 40 bytes,
    little-endian, floats as IEEE-754 bit patterns).
  - `init(decoding bytes: some Collection<UInt8>) throws(PenSample.DecodeError)`
  - `enum DecodeError: Error, Equatable { case wrongLength(Int), badMagic(UInt16),
    unsupportedVersion(UInt8), unknownKind(UInt8), invalidValue(field: String) }`
  - Validation on decode: x, y, pressure in 0…1; altitude in 0…π/2;
    azimuth in 0…2π; all floats finite. Out of range → `invalidValue`.
  - `static func isSequence(_ a: UInt32, newerThan b: UInt32) -> Bool` using
    serial-number arithmetic (RFC 1982 style: `Int32(bitPattern: a &- b) > 0`).
- Pure Swift + Foundation-free if practical; no platform `#if`.
- Tests go in `Packages/NibCore/Tests/NibCoreTests/PenSampleCodecTests.swift`
  using Swift Testing.

## Acceptance

- [ ] Golden vector test: a sample with kind `.move`, sequence `0x01020304`,
      timestamp `0x0102030405060708`, x 0.5, y 0.25, pressure 1.0, altitude 0,
      azimuth 0, hoverDistance `0xBEEF`, buttons `.eraser`, flags `.coalesced`
      encodes to a byte array asserted literally in the test (all 40 bytes).
- [ ] Round-trip test over every `Kind` and several field values.
- [ ] One test per `DecodeError` case, including NaN and infinity.
- [ ] Sequence tests: `newerThan` across wrap (`0` newer than `UInt32.max`),
      equal is not newer, half-range boundary.
- [ ] `scripts/verify.sh` passes.

## Out of scope

- Networking, framing, control messages, any app code.

## Handoff

```
Branch/commit: t3/pen-sample-codec @ bbebcdc
Verify: verify: ok (Test run with 12 tests; NibMac + NibPad built)
Done:
- Added PenSampleCodec.swift: encode(), init(decoding:) with full validation, isSequence wrap-aware compare
- Added PenSampleCodecTests.swift: golden 40-byte vector, round-trips, all DecodeError cases incl. NaN/Inf, sequence wrap/boundary tests
Manual checks: none required (no hardware/network path); not run
Not done / risks: none; reserved buttons/flags bits accepted as-is per decision 0002
```
