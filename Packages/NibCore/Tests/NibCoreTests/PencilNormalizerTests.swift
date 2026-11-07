import Testing

@testable import NibCore

@Test func normalizerClampsLocationAndPressure() {
  let result = PencilNormalizer.normalize(
    location: SIMD2(-10, 250), viewSize: SIMD2(100, 200), force: 3,
    maximumPossibleForce: 2, altitude: 4, azimuth: 0
  )
  #expect(result.x == 0)
  #expect(result.y == 1)
  #expect(result.pressure == 1)
  #expect(result.altitude == Float.pi / 2)
}

@Test func normalizerHandlesZeroMaximumForce() {
  let result = PencilNormalizer.normalize(
    location: SIMD2(50, 100), viewSize: SIMD2(100, 200), force: 1,
    maximumPossibleForce: 0, altitude: 0, azimuth: 0
  )
  #expect(result.pressure == 0)
}

@Test func normalizerWrapsNegativeAzimuth() {
  let result = PencilNormalizer.normalize(
    location: SIMD2(0, 0), viewSize: SIMD2(100, 100), force: 0,
    maximumPossibleForce: 1, altitude: 0, azimuth: -Float.pi / 2
  )
  #expect(abs(result.azimuth - Float.pi * 1.5) < 0.0001)
}

@Test func normalizerMapsHoverDistance() {
  let zero = PencilNormalizer.normalize(
    location: SIMD2(0, 0), viewSize: SIMD2(1, 1), force: 0,
    maximumPossibleForce: 1, altitude: 0, azimuth: 0, hoverZOffset: 0
  )
  let full = PencilNormalizer.normalize(
    location: SIMD2(0, 0), viewSize: SIMD2(1, 1), force: 0,
    maximumPossibleForce: 1, altitude: 0, azimuth: 0, hoverZOffset: 1
  )
  #expect(zero.hoverDistance == 0)
  #expect(full.hoverDistance == UInt16.max)
}
