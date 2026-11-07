import Testing

@testable import NibCore

@Test func keyNamesForKnownCodes() {
  #expect(KeyNames.name(for: 6) == "Z")
  #expect(KeyNames.name(for: 49) == "Space")
  #expect(KeyNames.name(for: 33) == "[")
  #expect(KeyNames.name(for: 9999) == nil)
}

@Test func chordDisplayUsesAppleModifierOrder() {
  #expect(KeyNames.displayName(for: .init(keyCode: 6, modifiers: [.shift, .command])) == "⇧⌘Z")
  #expect(
    KeyNames.displayName(for: .init(keyCode: 49, modifiers: [.command, .control, .option, .shift]))
      == "⌃⌥⇧⌘Space")
  #expect(KeyNames.displayName(for: .init(modifiers: [.control])) == "⌃")
  #expect(KeyNames.displayName(for: .init()) == "None")
  #expect(KeyNames.displayName(for: .init(keyCode: 200, modifiers: [.command])) == "⌘Key 200")
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
      if let code = button.chord.keyCode { #expect(KeyNames.name(for: code) != nil) }
    }
  }
}
