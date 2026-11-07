import Foundation

/// Converts UIKit Pencil measurements into the normalized values used by PenSample.
public struct PencilNormalizer: Sendable {
  public struct Result: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var altitude: Float
    public var azimuth: Float
    public var hoverDistance: UInt16

    public init(
      x: Float, y: Float, pressure: Float, altitude: Float, azimuth: Float,
      hoverDistance: UInt16
    ) {
      self.x = x
      self.y = y
      self.pressure = pressure
      self.altitude = altitude
      self.azimuth = azimuth
      self.hoverDistance = hoverDistance
    }
  }

  public static func normalize(
    location: SIMD2<Float>, viewSize: SIMD2<Float>, force: Float,
    maximumPossibleForce: Float, altitude: Float, azimuth: Float,
    hoverZOffset: Float? = nil
  ) -> Result {
    let x = clamp01(viewSize.x > 0 ? location.x / viewSize.x : 0)
    let y = clamp01(viewSize.y > 0 ? location.y / viewSize.y : 0)
    let pressure =
      maximumPossibleForce > 0
      ? clamp01(force / maximumPossibleForce) : 0
    let altitude = altitude.isNaN ? 0 : min(max(altitude, 0), .pi / 2)
    let azimuth = normalizedAzimuth(azimuth)
    let hoverDistance: UInt16
    if let hoverZOffset {
      hoverDistance = UInt16((clamp01(hoverZOffset) * Float(UInt16.max)).rounded())
    } else {
      hoverDistance = 0
    }
    return Result(
      x: x, y: y, pressure: pressure, altitude: altitude, azimuth: azimuth,
      hoverDistance: hoverDistance
    )
  }

  // NaN would survive min/max and then be rejected by the Mac's decoder,
  // dropping the sample; map it to 0 instead.
  private static func clamp01(_ value: Float) -> Float {
    value.isNaN ? 0 : min(max(value, 0), 1)
  }

  private static func normalizedAzimuth(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    let twoPi = Float.pi * 2
    var result = value.truncatingRemainder(dividingBy: twoPi)
    if result < 0 { result += twoPi }
    return result
  }
}
