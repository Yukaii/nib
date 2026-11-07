/// User settings owned by the iPad: the companion panel edits them, NibPad
/// applies the pressure curve before sending, and gesture options travel
/// with each gesture message so the Mac stays stateless.
public struct PadSettings: Codable, Equatable, Sendable {
  public struct Pressure: Codable, Equatable, Sendable {
    /// −1 soft … 0 linear … +1 firm.
    public var softness: Double
    /// Raw pressure below this maps to 0 (light-touch threshold), 0…0.5.
    public var minimum: Double
    /// Raw pressure at or above this maps to 1, 0.5…1.
    public var maximum: Double

    public init(softness: Double = 0, minimum: Double = 0, maximum: Double = 1) {
      self.softness = softness
      self.minimum = minimum
      self.maximum = maximum
    }

    public static let soft = Pressure(softness: -0.6)
    public static let linear = Pressure()
    public static let firm = Pressure(softness: 0.6)
  }

  public enum ZoomModifier: String, Codable, CaseIterable, Sendable {
    case command, option, control
  }

  public struct Gestures: Codable, Equatable, Sendable {
    public var twoFingerScroll: Bool
    public var pinchZoom: Bool
    public var zoomModifier: ZoomModifier
    /// Two-finger tap → undo, three-finger tap → redo (Procreate convention).
    public var tapUndoRedo: Bool

    public init(
      twoFingerScroll: Bool = true, pinchZoom: Bool = true, zoomModifier: ZoomModifier = .command,
      tapUndoRedo: Bool = true
    ) {
      self.twoFingerScroll = twoFingerScroll
      self.pinchZoom = pinchZoom
      self.zoomModifier = zoomModifier
      self.tapUndoRedo = tapUndoRedo
    }
  }

  public var pressure: Pressure
  public var gestures: Gestures

  public init(pressure: Pressure = .linear, gestures: Gestures = Gestures()) {
    self.pressure = pressure
    self.gestures = gestures
  }
}
