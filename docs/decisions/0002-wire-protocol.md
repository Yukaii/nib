# 0002 — Wire protocol: fixed-size PenSample packets

Date: 2026-11-07 · Status: accepted

## Decision

Every message is a fixed 40-byte little-endian packet. No JSON, no
variable-length framing on the hot path, so a datagram or a stream read of
40 bytes is always one sample.

| Offset | Size | Field        | Type    | Meaning                                              |
| ------ | ---- | ------------ | ------- | ---------------------------------------------------- |
| 0      | 2    | magic        | UInt16  | `0x4E42` ("NB")                                      |
| 2      | 1    | version      | UInt8   | `1`                                                  |
| 3      | 1    | kind         | UInt8   | 0 hover, 1 down, 2 move, 3 up, 4 cancel, 5 proximityExit |
| 4      | 4    | sequence     | UInt32  | wraps; receiver drops older-than-last within a window |
| 8      | 8    | timestamp    | UInt64  | sender monotonic nanoseconds                          |
| 16     | 4    | x            | Float32 | 0…1 across the iPad active area                       |
| 20     | 4    | y            | Float32 | 0…1, top = 0                                          |
| 24     | 4    | pressure     | Float32 | 0…1, `force / maximumPossibleForce`, 0 when hovering  |
| 28     | 4    | altitude     | Float32 | radians, 0 = flat, π/2 = perpendicular                |
| 32     | 4    | azimuth      | Float32 | radians, 0…2π, iPad view coordinates                  |
| 36     | 2    | hoverDistance| UInt16  | 0…65535 mapped from `zOffset` 0…1; 0 when touching    |
| 38     | 1    | buttons      | UInt8   | bit0 eraser, bit1 barrel (squeeze/double-tap action)  |
| 39     | 1    | flags        | UInt8   | bit0 predicted, bit1 coalesced                        |

Decoding rejects wrong magic, unknown version, unknown kind, wrong length,
and non-finite or out-of-range floats (clamped values are a decoder error,
not silently fixed).

The Swift type is `NibCore.PenSample`; the codec is `PenSample.encode()` /
`PenSample(decoding:)`.

## Consequences

- Version bump required for any layout change; the Mac shows "update the iPad
  app" on mismatch.
- Control messages (hello, display geometry, settings) are separate and not
  on the hot path; defined by the transport task (0005).
