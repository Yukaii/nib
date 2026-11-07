import Foundation

public struct SampleSequencer: Sendable, Equatable {
  private var lastSequence: UInt32?
  public init() {}
  public mutating func accept(_ sample: PenSample) -> Bool {
    guard let lastSequence else {
      self.lastSequence = sample.sequence
      return true
    }
    guard PenSample.isSequence(sample.sequence, newerThan: lastSequence) else { return false }
    self.lastSequence = sample.sequence
    return true
  }
  public mutating func reset() { lastSequence = nil }
  public var latestSequence: UInt32? { lastSequence }
}
