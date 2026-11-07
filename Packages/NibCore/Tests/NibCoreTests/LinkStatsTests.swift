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
}
