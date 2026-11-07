import Testing

@testable import NibCore

@Test func perpendicularPenHasNoTilt() {
  let tilt = TabletMath.tilt(altitude: .pi / 2, azimuth: 1.2)
  #expect(abs(tilt.x) < 0.0001)
  #expect(abs(tilt.y) < 0.0001)
}

@Test func flatPenFollowsAzimuth() {
  let x = TabletMath.tilt(altitude: 0, azimuth: 0)
  #expect(abs(x.x - 1) < 0.0001)
  #expect(abs(x.y) < 0.0001)
  let y = TabletMath.tilt(altitude: 0, azimuth: .pi / 2)
  #expect(abs(y.x) < 0.0001)
  #expect(abs(y.y - 1) < 0.0001)
}

@Test func tiltIsClamped() {
  let tilt = TabletMath.tilt(altitude: -.pi / 2, azimuth: .pi)
  #expect((-1...1).contains(tilt.x))
  #expect((-1...1).contains(tilt.y))
}
