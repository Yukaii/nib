import Foundation

/// Applies the capabilities of a known host without changing the user's saved profile.
public enum GestureCapabilityPolicy {
  public static func zoomMethod(
    _ method: PadSettings.ZoomMethod, host: ControlMessage.HostInfo?
  ) -> Gesture.ZoomMethod {
    let requested: Gesture.ZoomMethod = method == .nativeGesture ? .nativeGesture : .modifierScroll
    guard let host else { return requested }
    return host.capabilities.contains(ControlMessage.Capability.zoomNative)
      ? requested : .modifierScroll
  }

  public static func rotateEnabled(_ requested: Bool, host: ControlMessage.HostInfo?) -> Bool {
    guard let host else { return requested }
    return requested && host.capabilities.contains(ControlMessage.Capability.rotateNative)
  }
}
