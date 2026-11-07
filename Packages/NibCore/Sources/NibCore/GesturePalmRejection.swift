import Foundation

/// Pure timing policy that prevents a palm's fingers from becoming gestures near Pencil contact.
public struct GesturePalmRejection: Sendable, Equatable {
  public static let defaultGracePeriod: TimeInterval = 0.3
  public var gracePeriod: TimeInterval
  private var pencilActive = false
  private var pencilEndedAt: TimeInterval?

  public init(gracePeriod: TimeInterval = Self.defaultGracePeriod) {
    self.gracePeriod = gracePeriod
  }

  public mutating func pencilBegan() {
    pencilActive = true
    pencilEndedAt = nil
  }

  public mutating func pencilEnded(at time: TimeInterval) {
    pencilActive = false
    pencilEndedAt = time
  }

  public func suppresses(at time: TimeInterval) -> Bool {
    pencilActive || (pencilEndedAt.map { time - $0 < gracePeriod } ?? false)
  }
}
