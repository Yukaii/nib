import Foundation

/// Converts Pencil altitude and azimuth into Quartz tablet tilt coordinates.
public enum TabletMath {
  public static func tilt(altitude: Double, azimuth: Double) -> (x: Double, y: Double) {
    let x = cos(altitude) * cos(azimuth)
    let y = cos(altitude) * sin(azimuth)
    return (clamp(x), clamp(y))
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(-1, value))
  }
}
