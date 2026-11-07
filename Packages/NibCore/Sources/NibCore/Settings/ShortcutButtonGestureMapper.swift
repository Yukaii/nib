import Foundation

/// Maps the lifecycle of an edge shortcut button to wire gestures.
public enum ShortcutButtonGestureMapper {
  public enum Event: Sendable { case down, up, cancel }

  public static func gesture(
    for button: PadSettings.ShortcutButton, event: Event
  ) -> Gesture? {
    if button.hold {
      switch event {
      case .down: return .key(button.chord, action: .down)
      case .up, .cancel: return .key(button.chord, action: .up)
      }
    }
    guard event == .up else { return nil }
    return .key(button.chord, action: .tap)
  }
}
