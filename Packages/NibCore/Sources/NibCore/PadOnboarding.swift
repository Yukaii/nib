import Foundation

/// The action the iPad should take when Bonjour reports available Macs.
public enum MacSelection: Equatable, Sendable {
  case remembered(String)
  case single(String)
  case ask
}

/// Chooses a Mac without silently picking the wrong one when several are visible.
public enum MacSelectionPolicy {
  public static func choose(remembered: String?, results: [String]) -> MacSelection {
    let unique = Array(Set(results)).sorted()
    if let remembered, unique.contains(remembered) { return .remembered(remembered) }
    if unique.count == 1, let only = unique.first { return .single(only) }
    return .ask
  }
}

public enum PressureCheckResult: Equatable, Sendable {
  case notEnoughData
  case ok
  case noPressure
}

/// Classifies a short set of normalized Pencil force samples.
public enum PressureCheckClassifier {
  public static let minimumSamples = 8
  public static let minimumSpread: Float = 0.05

  public static func classify(_ samples: [Float]) -> PressureCheckResult {
    guard samples.count >= minimumSamples else { return .notEnoughData }
    let finite = samples.filter(\.isFinite).map { min(max($0, 0), 1) }
    guard finite.count >= minimumSamples else { return .notEnoughData }
    guard let minimum = finite.min(), let maximum = finite.max() else { return .notEnoughData }
    return maximum - minimum >= minimumSpread ? .ok : .noPressure
  }
}
