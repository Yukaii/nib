import Foundation

/// Tracks shortcut holds independently of UIKit view lifetime.
public struct ActiveHoldTracker: Equatable, Sendable {
  private var holds: [UUID: Gesture.KeyChord] = [:]

  public init() {}

  public mutating func begin(id: UUID, chord: Gesture.KeyChord) {
    holds[id] = chord
  }

  @discardableResult
  public mutating func end(id: UUID) -> Gesture? {
    guard let chord = holds.removeValue(forKey: id) else { return nil }
    return .key(chord, action: .up)
  }

  /// Releases every hold, used before controls are rebuilt or the app is suspended.
  public mutating func releaseAll() -> [Gesture] {
    let gestures = holds.values.map { Gesture.key($0, action: .up) }
    holds.removeAll()
    return gestures
  }
}
