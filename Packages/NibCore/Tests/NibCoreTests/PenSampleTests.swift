import Testing

@testable import NibCore

@Test func packetSizeMatchesDecision0002() {
  #expect(PenSample.byteCount == 40)
  #expect(PenSample.Kind.allCases.count == 6)
}
