import Testing

@testable import NibCore

@Test func keyNamesForKnownCodes() {
  #expect(KeyNames.name(for: "KeyZ") == "Z")
  #expect(KeyNames.name(for: "Space") == "Space")
  #expect(KeyNames.name(for: "BracketLeft") == "[")
  #expect(KeyNames.name(for: "Lang9") == nil)
}

@Test func chordDisplayUsesAppleModifierOrder() {
  #expect(KeyNames.displayName(for: .init(key: "KeyZ", modifiers: [.shift, .primary])) == "⇧⌘Z")
  #expect(
    KeyNames.displayName(for: .init(key: "Space", modifiers: [.primary, .control, .alt, .shift]))
      == "⌃⌥⇧⌘Space")
  #expect(
    KeyNames.displayName(for: .init(key: "KeyZ", modifiers: [.primary, .shift]), platform: .windows)
      == "Ctrl+Shift+Z")
  #expect(KeyNames.modifierSymbols([.primary, .control], platform: .linux) == "Ctrl")
  #expect(KeyNames.displayName(for: .init(modifiers: [.control])) == "⌃")
  #expect(KeyNames.displayName(for: .init()) == "None")
  #expect(KeyNames.displayName(for: .init(key: "Lang9", modifiers: [.primary])) == "⌘Lang9")
}

@Test func pickerTableHasUniqueCodesAndNames() {
  let keys = KeyNames.pickerKeys
  #expect(Set(keys.map(\.code)).count == keys.count)
  #expect(Set(keys.map(\.name)).count == keys.count)
  #expect(keys.count == 26 + 10 + 5 + 4 + 4 + 12)
}

@Test func presetKeysAreNameable() {
  for profile in PadSettings().profiles {
    for button in profile.buttons {
      if let code = button.chord.key { #expect(KeyNames.name(for: code) != nil) }
    }
  }
}
