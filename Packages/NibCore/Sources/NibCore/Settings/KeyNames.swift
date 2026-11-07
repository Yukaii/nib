import Foundation

/// Neutral W3C key names and their macOS translation for event injection.
public enum KeyNames {
  public enum Group: String, CaseIterable, Sendable {
    case letters = "Letters"
    case digits = "Digits"
    case editing = "Editing"
    case punctuation = "Punctuation"
    case arrows = "Arrows"
    case function = "Function"
  }
  public struct Key: Equatable, Sendable {
    public let code: String
    public let name: String
    public let group: Group
    public let macKeyCode: UInt16
  }

  public static let pickerKeys: [Key] = {
    func keys(_ group: Group, _ pairs: [(String, String, UInt16)]) -> [Key] {
      pairs.map { Key(code: $0.0, name: $0.1, group: group, macKeyCode: $0.2) }
    }
    return keys(
      .letters,
      [
        ("KeyA", "A", 0), ("KeyB", "B", 11), ("KeyC", "C", 8), ("KeyD", "D", 2), ("KeyE", "E", 14),
        ("KeyF", "F", 3), ("KeyG", "G", 5), ("KeyH", "H", 4), ("KeyI", "I", 34), ("KeyJ", "J", 38),
        ("KeyK", "K", 40), ("KeyL", "L", 37), ("KeyM", "M", 46), ("KeyN", "N", 45), ("KeyO", "O", 31),
        ("KeyP", "P", 35), ("KeyQ", "Q", 12), ("KeyR", "R", 15), ("KeyS", "S", 1), ("KeyT", "T", 17),
        ("KeyU", "U", 32), ("KeyV", "V", 9), ("KeyW", "W", 13), ("KeyX", "X", 7), ("KeyY", "Y", 16),
        ("KeyZ", "Z", 6),
      ])
      + keys(
        .digits,
        [
          ("Digit0", "0", 29), ("Digit1", "1", 18), ("Digit2", "2", 19), ("Digit3", "3", 20),
          ("Digit4", "4", 21), ("Digit5", "5", 23), ("Digit6", "6", 22), ("Digit7", "7", 26),
          ("Digit8", "8", 28), ("Digit9", "9", 25),
        ])
      + keys(
        .editing,
        [
          ("Space", "Space", 49), ("Tab", "Tab", 48), ("Escape", "Esc", 53), ("Delete", "Delete", 51),
          ("Enter", "Return", 36),
        ])
      + keys(
        .punctuation,
        [("BracketLeft", "[", 33), ("BracketRight", "]", 30), ("Minus", "-", 27), ("Equal", "=", 24)])
      + keys(
        .arrows,
        [("ArrowLeft", "←", 123), ("ArrowRight", "→", 124), ("ArrowDown", "↓", 125), ("ArrowUp", "↑", 126)])
      + keys(
        .function,
        [
          ("F1", "F1", 122), ("F2", "F2", 120), ("F3", "F3", 99), ("F4", "F4", 118), ("F5", "F5", 96),
          ("F6", "F6", 97), ("F7", "F7", 98), ("F8", "F8", 100), ("F9", "F9", 101), ("F10", "F10", 109),
          ("F11", "F11", 103), ("F12", "F12", 111),
        ])
  }()

  public static func keys(in group: Group) -> [Key] { pickerKeys.filter { $0.group == group } }
  public static func key(for code: String) -> Key? { pickerKeys.first { $0.code == code } }
  public static func w3cCode(forMacKeyCode code: UInt16) -> String? {
    pickerKeys.first { $0.macKeyCode == code }?.code
  }
  public static func name(for code: String) -> String? { key(for: code)?.name }

  public static func modifierSymbols(_ modifiers: Set<Gesture.Modifier>, platform: HostPlatform = .macos)
    -> String
  {
    if platform == .macos {
      let order: [(Gesture.Modifier, String)] = [
        (.control, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.primary, "⌘"), (.meta, "⌘"),
      ]
      return order.filter { modifiers.contains($0.0) }.map(\.1).joined()
    }
    let names: [(Gesture.Modifier, String)] = [
      (.primary, "Ctrl"), (.control, "Ctrl"), (.alt, "Alt"), (.shift, "Shift"), (.meta, "Meta"),
    ]
    var result: [String] = []
    for (modifier, name) in names where modifiers.contains(modifier) && !result.contains(name) {
      result.append(name)
    }
    return result.joined(separator: "+")
  }

  public static func displayName(for chord: Gesture.KeyChord, platform: HostPlatform = .macos) -> String {
    let prefix = modifierSymbols(chord.modifiers, platform: platform)
    guard let code = chord.key else { return prefix.isEmpty ? "None" : prefix }
    let name = name(for: code) ?? code
    return platform == .macos ? prefix + name : (prefix.isEmpty ? name : prefix + "+" + name)
  }
}
