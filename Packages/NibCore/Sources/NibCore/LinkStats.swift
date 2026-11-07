import Foundation

/// Measurements for the most recent two seconds of the pen stream.
public struct LinkStats: Sendable {
  public struct Snapshot: Sendable, Equatable {
    public var sampleRateHz: Double
    public var lossPercent: Double
    public var interArrivalP50Ms: Double
    public var interArrivalP95Ms: Double
    public var interArrivalMaxMs: Double
    public var delayVariationP50Ms: Double
    public var delayVariationP95Ms: Double
  }

  private struct Sample: Sendable {
    var sequence: UInt32
    var senderTimestampNs: UInt64
    var arrivalNs: UInt64
  }

  public static let windowNs: UInt64 = 2_000_000_000
  private var samples: [Sample] = []

  public init() {}

  public mutating func record(sequence: UInt32, senderTimestampNs: UInt64, arrivalNs: UInt64) {
    guard !samples.contains(where: { $0.sequence == sequence }) else { return }
    samples.append(.init(sequence: sequence, senderTimestampNs: senderTimestampNs, arrivalNs: arrivalNs))
    samples.removeAll { arrivalNs > $0.arrivalNs && arrivalNs - $0.arrivalNs > Self.windowNs }
  }

  public func snapshot(nowNs: UInt64) -> Snapshot {
    let recent = samples.filter { nowNs >= $0.arrivalNs && nowNs - $0.arrivalNs <= Self.windowNs }
      .sorted { $0.arrivalNs < $1.arrivalNs }
    guard !recent.isEmpty else {
      return .init(
        sampleRateHz: 0, lossPercent: 0, interArrivalP50Ms: 0, interArrivalP95Ms: 0, interArrivalMaxMs: 0,
        delayVariationP50Ms: 0, delayVariationP95Ms: 0)
    }
    let gaps = zip(recent, recent.dropFirst()).map { Double($1.arrivalNs - $0.arrivalNs) / 1_000_000 }
    let delays = recent.map { Int64($0.arrivalNs) - Int64($0.senderTimestampNs) }
    let minimum = delays.min() ?? 0
    let variation = delays.map { Double($0 - minimum) / 1_000_000 }
    var missing = 0
    for pair in zip(recent, recent.dropFirst()) {
      let distance = UInt64(pair.1.sequence &- pair.0.sequence)
      if distance < 0x8000_0000 { missing += Int(distance.saturatingSubtract(1)) }
    }
    return .init(
      sampleRateHz: Double(recent.count) / 2,
      lossPercent: Double(missing) * 100 / Double(recent.count + missing),
      interArrivalP50Ms: percentile(gaps, 0.50), interArrivalP95Ms: percentile(gaps, 0.95),
      interArrivalMaxMs: gaps.max() ?? 0,
      delayVariationP50Ms: percentile(variation, 0.50), delayVariationP95Ms: percentile(variation, 0.95))
  }

  private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
    return sorted[index]
  }
}

extension UInt64 {
  fileprivate func saturatingSubtract(_ value: UInt64) -> UInt64 { self > value ? self - value : 0 }
}
