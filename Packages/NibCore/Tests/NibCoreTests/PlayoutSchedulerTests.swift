import Testing

@testable import NibCore

struct PlayoutSchedulerTests {
  private func sample(_ sequence: UInt32, timestamp: UInt64, kind: PenSample.Kind = .move) -> PenSample {
    PenSample(
      kind: kind, sequence: sequence, timestamp: timestamp, x: 0.5, y: 0.5,
      pressure: kind == .move ? 0.5 : 0, altitude: 1, azimuth: 0)
  }

  @Test func burstIsReplayedAtSenderCadence() {
    var scheduler = PlayoutScheduler()
    let step: UInt64 = 4_170_000
    for index in 0..<4 {
      _ = scheduler.enqueue(
        sample(UInt32(index), timestamp: UInt64(index) * step),
        arrivalNs: 10_000_000 + UInt64(index) * 16_700_000)
    }
    let output = scheduler.drain(nowNs: 100_000_000)
    #expect(output.count == 4)
    #expect(output.map(\.sequence) == [0, 1, 2, 3])
  }

  @Test func lateSamplesPlayImmediatelyAndTransitionsAreKept() {
    var scheduler = PlayoutScheduler()
    _ = scheduler.enqueue(sample(1, timestamp: 1_000_000, kind: .down), arrivalNs: 1_000_000)
    _ = scheduler.enqueue(sample(2, timestamp: 2_000_000, kind: .up), arrivalNs: 2_000_000)
    #expect(scheduler.drain(nowNs: 100_000_000).map(\.sequence) == [1, 2])
  }

  @Test func gapReanchorsAndPassthroughIsImmediate() {
    var scheduler = PlayoutScheduler()
    _ = scheduler.enqueue(sample(1, timestamp: 0), arrivalNs: 1_000_000)
    _ = scheduler.enqueue(sample(2, timestamp: 200_000_000), arrivalNs: 201_000_000)
    #expect(scheduler.drain(nowNs: 205_000_000).map(\.sequence).last == 2)

    scheduler.setMode(.passthrough)
    #expect(scheduler.enqueue(sample(3, timestamp: 0), arrivalNs: 0).map(\.sequence) == [3])
  }

  @Test func delayStaysWithinClamp() {
    var scheduler = PlayoutScheduler()
    for index in 0..<20 {
      let sender = UInt64(index) * 5_000_000
      _ = scheduler.enqueue(sample(UInt32(index), timestamp: sender), arrivalNs: sender + 500_000_000)
    }
    #expect(scheduler.playoutDelayMs >= 2)
    #expect(scheduler.playoutDelayMs <= 40)
  }

  @Test func singleOutlierDoesNotSetTheDelay() {
    // p95, not max: one late packet among 120 must not hold every sample back.
    var scheduler = PlayoutScheduler()
    for index in 0..<120 {
      let sender = UInt64(index) * 4_166_667
      let lateness: UInt64 = index == 50 ? 30_000_000 : 0
      let sample = PenSample(
        kind: .move, sequence: UInt32(index), timestamp: sender, x: 0, y: 0, pressure: 0.5,
        altitude: 1, azimuth: 0)
      _ = scheduler.enqueue(sample, arrivalNs: sender + lateness)
    }
    #expect(scheduler.playoutDelayMs < 5)
  }
}
