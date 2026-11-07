import Testing

@testable import NibCore

private func goldenSample() -> PenSample {
  PenSample(
    kind: .move, sequence: 0x0102_0304, timestamp: 0x0102_0304_0506_0708,
    x: 0.5, y: 0.25, pressure: 1.0, altitude: 0, azimuth: 0,
    hoverDistance: 0xBEEF, buttons: .eraser, flags: .coalesced
  )
}

private func bytesWithFloat(
  _ value: Float, at offset: Int, base: PenSample = goldenSample()
) -> [UInt8] {
  var bytes = base.encode()
  let bits = value.bitPattern
  bytes[offset] = UInt8(truncatingIfNeeded: bits)
  bytes[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
  bytes[offset + 2] = UInt8(truncatingIfNeeded: bits >> 16)
  bytes[offset + 3] = UInt8(truncatingIfNeeded: bits >> 24)
  return bytes
}

@Test func goldenVectorEncodesAll40Bytes() {
  let expected: [UInt8] = [
    0x42, 0x4E, 0x01, 0x02,
    0x04, 0x03, 0x02, 0x01,
    0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    0x00, 0x00, 0x00, 0x3F,
    0x00, 0x00, 0x80, 0x3E,
    0x00, 0x00, 0x80, 0x3F,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0xEF, 0xBE, 0x01, 0x02,
  ]
  #expect(expected.count == PenSample.byteCount)
  #expect(goldenSample().encode() == expected)
}

@Test func goldenVectorDecodes() throws {
  let decoded = try PenSample(decoding: goldenSample().encode())
  #expect(decoded == goldenSample())
}

@Test func roundTripAllKinds() throws {
  for kind in PenSample.Kind.allCases {
    let sample = PenSample(
      kind: kind, sequence: 0xDEAD_BEEF, timestamp: .max,
      x: 0, y: 1, pressure: 0.123, altitude: Float.pi / 2, azimuth: 2 * Float.pi,
      hoverDistance: .max, buttons: [.eraser, .barrel],
      flags: [.predicted, .coalesced]
    )
    #expect(try PenSample(decoding: sample.encode()) == sample)
  }
}

@Test func roundTripEdgeValues() throws {
  let samples = [
    PenSample(
      kind: .hover, sequence: 0, timestamp: 0, x: 0, y: 0, pressure: 0,
      altitude: 0, azimuth: 0
    ),
    PenSample(
      kind: .down, sequence: 1, timestamp: 1, x: 1, y: 1, pressure: 1,
      altitude: Float.pi / 2, azimuth: 2 * Float.pi, hoverDistance: 1,
      buttons: .barrel, flags: .predicted
    ),
    PenSample(
      kind: .up, sequence: .max, timestamp: 999, x: 0.1, y: 0.9,
      pressure: 0.001, altitude: 1.0, azimuth: 3.14159, hoverDistance: 32767
    ),
  ]
  for sample in samples {
    #expect(try PenSample(decoding: sample.encode()) == sample)
  }
}

@Test func decodeRejectsWrongLength() {
  #expect(throws: PenSample.DecodeError.wrongLength(0)) {
    try PenSample(decoding: [UInt8]())
  }
  #expect(throws: PenSample.DecodeError.wrongLength(39)) {
    try PenSample(decoding: Array(goldenSample().encode().prefix(39)))
  }
  let long = goldenSample().encode() + [0x00]
  #expect(throws: PenSample.DecodeError.wrongLength(41)) {
    try PenSample(decoding: long)
  }
}

@Test func decodeRejectsBadMagic() {
  var bytes = goldenSample().encode()
  bytes[0] = 0x00
  bytes[1] = 0x00
  #expect(throws: PenSample.DecodeError.badMagic(0x0000)) {
    try PenSample(decoding: bytes)
  }
}

@Test func decodeRejectsUnsupportedVersion() {
  var bytes = goldenSample().encode()
  bytes[2] = 0x7F
  #expect(throws: PenSample.DecodeError.unsupportedVersion(0x7F)) {
    try PenSample(decoding: bytes)
  }
}

@Test func decodeRejectsUnknownKind() {
  var bytes = goldenSample().encode()
  bytes[3] = 0x06
  #expect(throws: PenSample.DecodeError.unknownKind(0x06)) {
    try PenSample(decoding: bytes)
  }
}

@Test func decodeRejectsOutOfRangeFloats() {
  #expect(throws: PenSample.DecodeError.invalidValue(field: "x")) {
    try PenSample(decoding: bytesWithFloat(-0.1, at: 16))
  }
  #expect(throws: PenSample.DecodeError.invalidValue(field: "x")) {
    try PenSample(decoding: bytesWithFloat(1.1, at: 16))
  }
  #expect(throws: PenSample.DecodeError.invalidValue(field: "y")) {
    try PenSample(decoding: bytesWithFloat(2.0, at: 20))
  }
  #expect(throws: PenSample.DecodeError.invalidValue(field: "pressure")) {
    try PenSample(decoding: bytesWithFloat(-1.0, at: 24))
  }
  #expect(throws: PenSample.DecodeError.invalidValue(field: "altitude")) {
    try PenSample(decoding: bytesWithFloat(Float.pi, at: 28))
  }
  #expect(throws: PenSample.DecodeError.invalidValue(field: "azimuth")) {
    try PenSample(decoding: bytesWithFloat(2 * Float.pi + 0.001, at: 32))
  }
}

@Test func decodeRejectsNonFiniteFloats() {
  for (field, offset) in [
    ("x", 16), ("y", 20), ("pressure", 24), ("altitude", 28),
    ("azimuth", 32),
  ] {
    #expect(throws: PenSample.DecodeError.invalidValue(field: field)) {
      try PenSample(decoding: bytesWithFloat(.nan, at: offset))
    }
    #expect(throws: PenSample.DecodeError.invalidValue(field: field)) {
      try PenSample(decoding: bytesWithFloat(.infinity, at: offset))
    }
    #expect(throws: PenSample.DecodeError.invalidValue(field: field)) {
      try PenSample(decoding: bytesWithFloat(-.infinity, at: offset))
    }
  }
}

@Test func sequenceComparison() {
  #expect(PenSample.isSequence(2, newerThan: 1))
  #expect(!PenSample.isSequence(1, newerThan: 2))
  #expect(!PenSample.isSequence(5, newerThan: 5))
  // Wrap: 0 follows UInt32.max.
  #expect(PenSample.isSequence(0, newerThan: .max))
  #expect(!PenSample.isSequence(.max, newerThan: 0))
  // Half-range boundary: a difference of exactly 2^31 is not newer.
  #expect(!PenSample.isSequence(0x8000_0000, newerThan: 0))
  #expect(!PenSample.isSequence(0, newerThan: 0x8000_0000))
  #expect(PenSample.isSequence(0x7FFF_FFFF, newerThan: 0))
  #expect(!PenSample.isSequence(0x8000_0001, newerThan: 0))
}
