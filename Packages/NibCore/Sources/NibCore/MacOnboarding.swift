/// The macOS setup step is derived from live connection and permission state.
public enum MacOnboardingStep: Equatable, Sendable {
  case accessibility
  case restart
  case connect
  case tryIt
  case completed

  public static func resolve(
    trusted: Bool,
    needsRestart: Bool,
    connected: Bool,
    setupCompleted: Bool
  ) -> Self {
    if setupCompleted { return .completed }
    if !trusted { return .accessibility }
    if needsRestart { return .restart }
    if !connected { return .connect }
    return .tryIt
  }
}
