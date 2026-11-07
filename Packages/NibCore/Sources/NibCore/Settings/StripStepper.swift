import Foundation

/// Converts a continuous strip distance into signed whole steps.
public struct StripStepper: Equatable, Sendable {
  public let step: Double
  public private(set) var remainder: Double = 0
  private var direction: Int = 0

  public init(step: Double = 24) {
    self.step = max(step.isFinite && step > 0 ? step : 24, .leastNonzeroMagnitude)
  }

  /// Adds points in strip coordinates. Positive values mean up; the return
  /// value is the number of whole steps, positive for up and negative for down.
  public mutating func add(_ points: Double) -> Int {
    guard points.isFinite, points != 0 else { return 0 }
    let newDirection = points > 0 ? 1 : -1
    if direction != 0, newDirection != direction { remainder = 0 }
    direction = newDirection
    remainder += points
    let count = Int(remainder / step)
    remainder -= Double(count) * step
    return count
  }

  /// Drops the partial distance at the end of a finger slide.
  public mutating func end() {
    remainder = 0
    direction = 0
  }
}
