extension PenSample {
  public enum DecodeError: Error, Equatable, Sendable {
    case wrongLength(Int)
    case badMagic(UInt16)
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case invalidValue(field: String)
  }

  public func encode() -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(Self.byteCount)
    append(Self.magic, to: &bytes)
    bytes.append(Self.version)
    bytes.append(kind.rawValue)
    append(sequence, to: &bytes)
    append(timestamp, to: &bytes)
    append(x.bitPattern, to: &bytes)
    append(y.bitPattern, to: &bytes)
    append(pressure.bitPattern, to: &bytes)
    append(altitude.bitPattern, to: &bytes)
    append(azimuth.bitPattern, to: &bytes)
    append(hoverDistance, to: &bytes)
    bytes.append(buttons.rawValue)
    bytes.append(flags.rawValue)
    return bytes
  }

  public init(decoding bytes: some Collection<UInt8>) throws(DecodeError) {
    let bytes = Array(bytes)
    guard bytes.count == Self.byteCount else {
      throw .wrongLength(bytes.count)
    }
    let magic = load(UInt16.self, from: bytes, at: 0)
    guard magic == Self.magic else {
      throw .badMagic(magic)
    }
    let version = bytes[2]
    guard version == Self.version else {
      throw .unsupportedVersion(version)
    }
    let kindRaw = bytes[3]
    guard let kind = Kind(rawValue: kindRaw) else {
      throw .unknownKind(kindRaw)
    }
    let sequence = load(UInt32.self, from: bytes, at: 4)
    let timestamp = load(UInt64.self, from: bytes, at: 8)
    let x = Float(bitPattern: load(UInt32.self, from: bytes, at: 16))
    let y = Float(bitPattern: load(UInt32.self, from: bytes, at: 20))
    let pressure = Float(bitPattern: load(UInt32.self, from: bytes, at: 24))
    let altitude = Float(bitPattern: load(UInt32.self, from: bytes, at: 28))
    let azimuth = Float(bitPattern: load(UInt32.self, from: bytes, at: 32))
    let hoverDistance = load(UInt16.self, from: bytes, at: 36)
    let buttons = Buttons(rawValue: bytes[38])
    let flags = Flags(rawValue: bytes[39])
    try Self.validate(x, field: "x", range: 0...1)
    try Self.validate(y, field: "y", range: 0...1)
    try Self.validate(pressure, field: "pressure", range: 0...1)
    try Self.validate(altitude, field: "altitude", range: 0...(Float.pi / 2))
    try Self.validate(azimuth, field: "azimuth", range: 0...(2 * Float.pi))
    self.init(
      kind: kind, sequence: sequence, timestamp: timestamp, x: x, y: y,
      pressure: pressure, altitude: altitude, azimuth: azimuth,
      hoverDistance: hoverDistance, buttons: buttons, flags: flags
    )
  }

  /// Wrap-aware sequence comparison (RFC 1982 serial-number arithmetic).
  public static func isSequence(_ a: UInt32, newerThan b: UInt32) -> Bool {
    Int32(bitPattern: a &- b) > 0
  }

  private static func validate(
    _ value: Float, field: String, range: ClosedRange<Float>
  ) throws(DecodeError) {
    guard value.isFinite, range.contains(value) else {
      throw .invalidValue(field: field)
    }
  }
}

private func append(_ value: UInt16, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func append(_ value: UInt32, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
  bytes.append(UInt8(truncatingIfNeeded: value >> 16))
  bytes.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func append(_ value: UInt64, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
  bytes.append(UInt8(truncatingIfNeeded: value >> 16))
  bytes.append(UInt8(truncatingIfNeeded: value >> 24))
  bytes.append(UInt8(truncatingIfNeeded: value >> 32))
  bytes.append(UInt8(truncatingIfNeeded: value >> 40))
  bytes.append(UInt8(truncatingIfNeeded: value >> 48))
  bytes.append(UInt8(truncatingIfNeeded: value >> 56))
}

private func load(_ type: UInt16.Type, from bytes: [UInt8], at offset: Int) -> UInt16 {
  UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func load(_ type: UInt32.Type, from bytes: [UInt8], at offset: Int) -> UInt32 {
  UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
    | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
}

private func load(_ type: UInt64.Type, from bytes: [UInt8], at offset: Int) -> UInt64 {
  UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8)
    | (UInt64(bytes[offset + 2]) << 16) | (UInt64(bytes[offset + 3]) << 24)
    | (UInt64(bytes[offset + 4]) << 32) | (UInt64(bytes[offset + 5]) << 40)
    | (UInt64(bytes[offset + 6]) << 48) | (UInt64(bytes[offset + 7]) << 56)
}
