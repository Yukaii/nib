import NibCore
import Testing

struct ShortcutButtonGestureMapperTests {
  private let chord = Gesture.KeyChord(key: "KeyB", modifiers: [.primary])

  @Test func tapButtonEmitsOneTapOnRelease() {
    let button = PadSettings.ShortcutButton(label: "B", chord: chord)
    #expect(ShortcutButtonGestureMapper.gesture(for: button, event: .down) == nil)
    #expect(
      ShortcutButtonGestureMapper.gesture(for: button, event: .up)
        == .key(chord, action: .tap))
  }

  @Test func holdButtonEndsOnReleaseOrCancel() {
    let button = PadSettings.ShortcutButton(label: "Pan", chord: chord, hold: true)
    #expect(
      ShortcutButtonGestureMapper.gesture(for: button, event: .down)
        == .key(chord, action: .down))
    #expect(
      ShortcutButtonGestureMapper.gesture(for: button, event: .up)
        == .key(chord, action: .up))
    #expect(
      ShortcutButtonGestureMapper.gesture(for: button, event: .cancel)
        == .key(chord, action: .up))
  }
}
