import NibCore
import Testing

struct LinkStatsTests {
  @Test func steadyStreamAndDuplicateTransitions() {
    var stats = LinkStats()
    for sequence in 0..<480 {
      let time = UInt64(sequence) * 4_166_667
      stats.record(sequence: UInt32(sequence), senderTimestampNs: time, arrivalNs: time)
    }
    stats.record(sequence: 479, senderTimestampNs: 0, arrivalNs: 2_000_000_000)
    let snapshot = stats.snapshot(nowNs: 2_000_000_000)
    #expect(snapshot.sampleRateHz == 240)
    #expect(snapshot.lossPercent == 0)
    #expect(abs(snapshot.interArrivalP50Ms - 4.166667) < 0.01)
  }

  @Test func sequenceGapAndClockOffset() {
    var stats = LinkStats()
    for sequence in 0..<20 {
      let time = UInt64(sequence) * 16_666_667
      stats.record(
        sequence: UInt32(sequence + (sequence >= 10 ? 10 : 0)), senderTimestampNs: time,
        arrivalNs: time + 500_000_000)
    }
    let snapshot = stats.snapshot(nowNs: 2_000_000_000)
    #expect(snapshot.lossPercent > 30 && snapshot.lossPercent < 35)
    #expect(snapshot.delayVariationP95Ms == 0)
  }

  @Test func burstyFramesShowFrameSizedGaps() {
    // iPad mini delivers 240 Hz Pencil samples ~4 per 60 Hz frame.
    var stats = LinkStats()
    for frame in 0..<120 {
      let frameArrival = UInt64(frame) * 16_666_667
      for index in 0..<4 {
        let sequence = frame * 4 + index
        stats.record(
          sequence: UInt32(sequence), senderTimestampNs: UInt64(sequence) * 4_166_667,
          arrivalNs: frameArrival + UInt64(index) * 50_000)
      }
    }
    let snapshot = stats.snapshot(nowNs: 119 * 16_666_667)
    #expect(abs(snapshot.interArrivalP95Ms - 16.5) < 0.5)
    #expect(snapshot.interArrivalP50Ms < 1)
    #expect(snapshot.lossPercent == 0)
  }
}
