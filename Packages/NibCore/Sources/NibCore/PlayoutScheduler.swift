import Foundation

/// Deterministic, FIFO playout for samples arriving with sender timestamps.
public struct PlayoutScheduler: Sendable {
  public enum Mode: Sendable, Equatable { case smoothing, passthrough }
  private struct TimedSample: Sendable {
    var sample: PenSample
    var arrivalNs: UInt64
  }
  private struct Observation: Sendable {
    var senderNs: UInt64
    var arrivalNs: UInt64
  }
  private static let windowNs: UInt64 = 2_000_000_000
  private static let gapNs: UInt64 = 100_000_000
  private var mode: Mode
  private var offsetNs: UInt64?
  private var queue: [TimedSample] = []
  private var observations: [Observation] = []
  private var lastSenderNs: UInt64?
  private var samplesSinceDelayUpdate = 0
  // Recomputing the p95 sorts the 2 s window; ~100 ms granularity is enough.
  private static let delayUpdateInterval = 24
  public private(set) var playoutDelayMs: Double = 2

  public init(mode: Mode = .smoothing) { self.mode = mode }
  public var hasPending: Bool { !queue.isEmpty }
  public var isPassthrough: Bool { mode == .passthrough }
  public mutating func setMode(_ mode: Mode) {
    self.mode = mode
    if mode == .passthrough { queue.removeAll() }
  }

  /// Enqueues one sample. Passthrough returns it immediately; smoothing emits on drain.
  public mutating func enqueue(_ sample: PenSample, arrivalNs: UInt64) -> [PenSample] {
    if mode == .passthrough { return [sample] }
    if let lastSenderNs, sample.timestamp > lastSenderNs,
      sample.timestamp - lastSenderNs > Self.gapNs
    {
      offsetNs = arrivalNs >= sample.timestamp ? arrivalNs - sample.timestamp : 0
      observations.removeAll()
    }
    lastSenderNs = sample.timestamp
    let offset = arrivalNs >= sample.timestamp ? arrivalNs - sample.timestamp : 0
    observations.append(.init(senderNs: sample.timestamp, arrivalNs: arrivalNs))
    observations.removeAll { arrivalNs > $0.arrivalNs && arrivalNs - $0.arrivalNs > Self.windowNs }
    offsetNs =
      observations.map { $0.arrivalNs >= $0.senderNs ? $0.arrivalNs - $0.senderNs : 0 }.min() ?? offset
    samplesSinceDelayUpdate += 1
    if samplesSinceDelayUpdate >= Self.delayUpdateInterval || observations.count == 1 {
      samplesSinceDelayUpdate = 0
      let base = offsetNs ?? offset
      let residuals = observations.map { Int64($0.arrivalNs) - Int64($0.senderNs) - Int64(base) }
      let p95 = percentile(residuals.map { Double(max(0, $0)) / 1_000_000 }, 0.95)
      playoutDelayMs = min(40, max(2, p95 + 2))
    }
    queue.append(.init(sample: sample, arrivalNs: arrivalNs))
    return []
  }

  public mutating func drain(nowNs: UInt64) -> [PenSample] {
    guard mode == .smoothing, let base = offsetNs else { return [] }
    var output: [PenSample] = []
    while let first = queue.first {
      let target = first.sample.timestamp &+ base &+ UInt64(playoutDelayMs * 1_000_000)
      if target > nowNs && !isLate(first, nowNs: nowNs) { break }
      output.append(first.sample)
      queue.removeFirst()
    }
    return output
  }

  private func isLate(_ item: TimedSample, nowNs: UInt64) -> Bool {
    nowNs >= item.arrivalNs && nowNs - item.arrivalNs >= UInt64(playoutDelayMs * 1_000_000)
  }
  private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
  }
}
