import Foundation

public struct SampleSequencer: Sendable {
  private var lastSequence: UInt32?
  public init() {}
  public mutating func accept(_ sample: PenSample) -> Bool {
    guard let lastSequence else {
      self.lastSequence = sample.sequence
      return true
    }
    let distance = sample.sequence &- lastSequence
    guard distance != 0 && distance < 0x8000_0000 else { return false }
    self.lastSequence = sample.sequence
    return true
  }
  public mutating func reset() { lastSequence = nil }
  public var latestSequence: UInt32? { lastSequence }
}
