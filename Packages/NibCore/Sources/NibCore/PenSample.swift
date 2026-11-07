/// One Apple Pencil sample as sent from the iPad to the Mac.
/// Wire layout: docs/decisions/0002-wire-protocol.md.
public struct PenSample: Sendable, Equatable {
  public enum Kind: UInt8, Sendable, CaseIterable {
    case hover = 0
    case down = 1
    case move = 2
    case up = 3
    case cancel = 4
    case proximityExit = 5
  }

  public struct Buttons: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let eraser = Buttons(rawValue: 1 << 0)
    public static let barrel = Buttons(rawValue: 1 << 1)
  }

  public struct Flags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let predicted = Flags(rawValue: 1 << 0)
    public static let coalesced = Flags(rawValue: 1 << 1)
  }

  public var kind: Kind
  public var sequence: UInt32
  /// Sender monotonic clock, nanoseconds.
  public var timestamp: UInt64
  /// 0…1 across the iPad active area, origin top-left.
  public var x: Float
  public var y: Float
  /// 0…1; 0 while hovering.
  public var pressure: Float
  /// Radians; 0 = flat on the glass, π/2 = perpendicular.
  public var altitude: Float
  /// Radians, 0…2π, in iPad view coordinates.
  public var azimuth: Float
  /// 0…65535 mapped from hover zOffset 0…1; 0 while touching.
  public var hoverDistance: UInt16
  public var buttons: Buttons
  public var flags: Flags

  public init(
    kind: Kind, sequence: UInt32, timestamp: UInt64, x: Float, y: Float,
    pressure: Float, altitude: Float, azimuth: Float, hoverDistance: UInt16 = 0,
    buttons: Buttons = [], flags: Flags = []
  ) {
    self.kind = kind
    self.sequence = sequence
    self.timestamp = timestamp
    self.x = x
    self.y = y
    self.pressure = pressure
    self.altitude = altitude
    self.azimuth = azimuth
    self.hoverDistance = hoverDistance
    self.buttons = buttons
    self.flags = flags
  }

  public static let magic: UInt16 = 0x4E42
  public static let version: UInt8 = 1
  public static let byteCount = 40
}
