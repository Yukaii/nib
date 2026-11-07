import CoreGraphics
import Testing
@testable import NibCore

private func mappedSample(x: Float, y: Float, pressure: Float = 0) -> PenSample {
  PenSample(
    kind: .move, sequence: 0, timestamp: 0, x: x, y: y, pressure: pressure, altitude: 1,
    azimuth: 0)
}

@Test func widerDisplayMapsActiveAreaCorners() {
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 1_000, height: 1_000),
    displayRect: CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
  #expect(mapper.map(mappedSample(x: 0, y: 0.25)).x == 0)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 0.75)).x - 1_999.999999) < 0.01)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 0.75)).y - 999.999999) < 0.01)
}

@Test func tallerDisplayMapsActiveAreaCorners() {
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 1_000, height: 1_000),
    displayRect: CGRect(x: 10, y: 20, width: 1_000, height: 2_000))
  #expect(mapper.map(mappedSample(x: 0.25, y: 0)) == CGPoint(x: 10, y: 20))
  #expect(abs(mapper.map(mappedSample(x: 0.75, y: 1)).x - 1_009.999999) < 0.01)
  #expect(abs(mapper.map(mappedSample(x: 0.75, y: 1)).y - 2_019.999999) < 0.01)
}

@Test func deadBandClampsToDisplayEdgeAndSupportsNegativeOrigin() {
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 2_000, height: 1_000),
    displayRect: CGRect(x: -1_440, y: 0, width: 1_440, height: 900))
  #expect(abs(mapper.map(mappedSample(x: 0, y: 0.5)).x + 1_440) < 0.01)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 0.5)).x + 0.000001) < 0.01)
}

@Test func zeroSurfaceUsesFullNormalizedSurface() {
  let mapper = DisplayMapper(
    surfaceSize: .zero, displayRect: CGRect(x: 4, y: -3, width: 100, height: 50))
  let point = mapper.map(mappedSample(x: 0.5, y: 0.25))
  #expect(abs(point.x - 54) < 0.01)
  #expect(abs(point.y - 9.5) < 0.01)
}
