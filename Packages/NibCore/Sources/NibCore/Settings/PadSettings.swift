import Foundation

/// User settings owned by the iPad. Profiles select the gesture options and
/// shortcut layout for the Mac application currently in front.
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
  public enum ZoomModifier: String, Codable, CaseIterable, Sendable { case command, option, control }
  public enum StripMode: String, Codable, Sendable { case scroll, zoom, brushSize, off }
  public enum StripSide: String, Codable, Sendable { case left, right }
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
  public struct ShortcutButton: Codable, Equatable, Sendable {
    public var label: String
    public var chord: Gesture.KeyChord
    public var hold: Bool
    public init(label: String, chord: Gesture.KeyChord, hold: Bool = false) {
      self.label = label
      self.chord = chord
      self.hold = hold
    }
  }
  public struct Strip: Codable, Equatable, Sendable {
    public var mode: StripMode
    public var side: StripSide
    public init(mode: StripMode = .off, side: StripSide = .right) {
      self.mode = mode
      self.side = side
    }
  }
  public struct Profile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var bundleIDPrefixes: [String]
    public var buttons: [ShortcutButton]
    public var strip: Strip
    public var gestures: Gestures
    public init(
      id: UUID = UUID(), name: String, bundleIDPrefixes: [String] = [], buttons: [ShortcutButton] = [],
      strip: Strip = Strip(), gestures: Gestures = Gestures()
    ) {
      self.id = id
      self.name = name
      self.bundleIDPrefixes = bundleIDPrefixes
      self.buttons = buttons
      self.strip = strip
      self.gestures = gestures
    }
    public var canAddButton: Bool { buttons.count < PadSettings.maxButtons }
    /// Appends a blank button (no key yet); returns false at the button limit.
    @discardableResult
    public mutating func addButton() -> Bool {
      guard canAddButton else { return false }
      buttons.append(ShortcutButton(label: "New", chord: .init()))
      return true
    }
    /// Moves a button by `offset` places, clamped to the list.
    public mutating func moveButton(at index: Int, by offset: Int) {
      guard buttons.indices.contains(index) else { return }
      let target = min(max(index + offset, 0), buttons.count - 1)
      guard target != index else { return }
      buttons.insert(buttons.remove(at: index), at: target)
    }
  }
  public var pressure: Pressure
  /// The first profile is always Default: the fallback for unbound apps.
  public var profiles: [Profile]
  public static let maxButtons = 8
  public init(pressure: Pressure = .linear, gestures: Gestures = Gestures()) {
    self.pressure = pressure
    self.profiles = Self.presets(defaultGestures: gestures)
  }
  public func profile(forBundleID bundleID: String) -> Profile {
    // Default (first) is never bound to apps, and an empty prefix, which a
    // half-typed text field can produce, must not match everything.
    profiles.dropFirst().first(where: {
      $0.bundleIDPrefixes.contains(where: { !$0.isEmpty && bundleID.hasPrefix($0) })
    }) ?? profiles.first ?? Profile(name: "Default")
  }
  public func isDefault(_ id: UUID) -> Bool { profiles.first?.id == id }
  /// Adds a copy of Default's buttons and gestures, unbound to any app.
  @discardableResult
  public mutating func addProfile() -> UUID {
    var profile = profiles.first ?? Profile(name: "Default")
    profile.id = UUID()
    profile.name = "New profile"
    profile.bundleIDPrefixes = []
    profiles.append(profile)
    return profile.id
  }
  /// Default cannot be deleted. Returns whether a profile was removed.
  @discardableResult
  public mutating func deleteProfile(id: UUID) -> Bool {
    guard !isDefault(id), let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
    profiles.remove(at: index)
    return true
  }
  /// Restores the four built-in profiles; pressure calibration is kept.
  public mutating func resetProfilesToPresets() { profiles = Self.presets() }
  private enum CodingKeys: String, CodingKey { case pressure, profiles, gestures }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    pressure = try values.decodeIfPresent(Pressure.self, forKey: .pressure) ?? .linear
    if let decoded = try values.decodeIfPresent([Profile].self, forKey: .profiles) {
      profiles = decoded.isEmpty ? Self.presets() : decoded
    } else {
      profiles = Self.presets(
        defaultGestures: try values.decodeIfPresent(Gestures.self, forKey: .gestures) ?? Gestures())
    }
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(pressure, forKey: .pressure)
    try values.encode(profiles, forKey: .profiles)
  }
  private static func chord(_ code: UInt16, _ modifiers: Set<Gesture.Modifier> = []) -> Gesture.KeyChord {
    .init(keyCode: code, modifiers: modifiers)
  }
  private static func buttons(_ pairs: [(String, Gesture.KeyChord, Bool)]) -> [ShortcutButton] {
    pairs.map { .init(label: $0.0, chord: $0.1, hold: $0.2) }
  }
  private static func presets(defaultGestures: Gestures = Gestures()) -> [Profile] {
    let command: Set<Gesture.Modifier> = [.command]
    let shiftCommand: Set<Gesture.Modifier> = [.command, .shift]
    let z = chord(6, command)
    let redo = chord(6, shiftCommand)
    let b = chord(11)
    let e = chord(14)
    let space = chord(49)
    let left = chord(33)
    let right = chord(30)
    let pan = ShortcutButton(label: "Pan", chord: space, hold: true)
    let base = buttons([
      ("Undo", z, false), ("Redo", redo, false), ("B", b, false), ("E", e, false), ("[", left, false),
      ("]", right, false),
    ])
    return [
      Profile(name: "Default", buttons: base + [pan], gestures: defaultGestures),
      Profile(
        name: "Krita", bundleIDPrefixes: ["org.kde.krita"],
        buttons: base + [pan, .init(label: "Pick", chord: .init(modifiers: [.control]), hold: true)],
        gestures: .init(zoomModifier: .control)),
      Profile(
        name: "Photoshop", bundleIDPrefixes: ["com.adobe.Photoshop"],
        buttons: base + [pan, .init(label: "Alt", chord: .init(modifiers: [.option]), hold: true)],
        gestures: .init(zoomModifier: .option)),
      Profile(
        name: "Affinity", bundleIDPrefixes: ["com.seriflabs."], buttons: base,
        gestures: .init(zoomModifier: .command)),
    ]
  }
}
