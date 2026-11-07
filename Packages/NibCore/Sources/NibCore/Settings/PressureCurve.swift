import Foundation

public enum PressureCurve {
  /// Maps normalized Pencil pressure through the user's calibrated curve.
  public static func apply(_ raw: Float, _ pressure: PadSettings.Pressure) -> Float {
    let minimum = Float(min(max(pressure.minimum, 0), 0.5))
    let maximum = Float(min(max(pressure.maximum, 0.5), 1))
    let normalized = min(max((raw - minimum) / max(maximum - minimum, 0.0001), 0), 1)
    let softness = min(max(pressure.softness, -1), 1)
    let gamma = Foundation.pow(2.0, 1.5 * softness)
    let output = Foundation.pow(Double(normalized), gamma)
    return output.isFinite ? min(max(Float(output), 0), 1) : 0
  }
}
