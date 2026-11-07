import Foundation

/// Display names for macOS virtual key codes, so the iPad can offer a key
/// picker without a hardware keyboard. Codes are the ANSI `kVK_*` values.
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
    public let code: UInt16
    public let name: String
    public let group: Group
  }

  /// Every key the picker offers, in display order.
  public static let pickerKeys: [Key] = {
    func keys(_ group: Group, _ pairs: [(UInt16, String)]) -> [Key] {
      pairs.map { Key(code: $0.0, name: $0.1, group: group) }
    }
    return keys(
      .letters,
      [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"),
        (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"),
        (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
      ])
      + keys(
        .digits,
        [
          (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"),
          (28, "8"), (25, "9"),
        ])
      + keys(
        .editing,
        [(49, "Space"), (48, "Tab"), (53, "Esc"), (51, "Delete"), (36, "Return")])
      + keys(.punctuation, [(33, "["), (30, "]"), (27, "-"), (24, "=")])
      + keys(.arrows, [(123, "←"), (124, "→"), (125, "↓"), (126, "↑")])
      + keys(
        .function,
        [
          (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"),
          (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ])
  }()

  public static func keys(in group: Group) -> [Key] { pickerKeys.filter { $0.group == group } }

  public static func name(for code: UInt16) -> String? {
    pickerKeys.first(where: { $0.code == code })?.name
  }

  /// Apple's modifier order: ⌃⌥⇧⌘.
  public static func modifierSymbols(_ modifiers: Set<Gesture.Modifier>) -> String {
    let ordered: [(Gesture.Modifier, String)] = [
      (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]
    return ordered.filter { modifiers.contains($0.0) }.map(\.1).joined()
  }

  /// "⇧⌘Z" for a key chord; modifier-only chords show just the symbols.
  public static func displayName(for chord: Gesture.KeyChord) -> String {
    let symbols = modifierSymbols(chord.modifiers)
    guard let code = chord.keyCode else { return symbols.isEmpty ? "None" : symbols }
    return symbols + (name(for: code) ?? "Key \(code)")
  }
}
