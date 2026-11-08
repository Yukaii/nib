import Foundation
import Testing

@testable import NibCore

@Test func padSettingsRoundTripAndDefaults() throws {
  let settings = PadSettings(
    pressure: .firm, gestures: .init(pinchZoom: false, zoomModifier: .alt))
  let data = try JSONEncoder().encode(settings)
  #expect(try JSONDecoder().decode(PadSettings.self, from: data) == settings)
  #expect(PadSettings().pressure == .linear)
  #expect(PadSettings().profiles[0].gestures.tapUndoRedo)
}

@Test func oldSettingsDecodeToPresetsWithoutLosingPressure() throws {
  let json =
    #"{"pressure":{"softness":0.6,"minimum":0.1,"maximum":0.9},"gestures":{"twoFingerScroll":true,"pinchZoom":true,"zoomModifier":"option","tapUndoRedo":true}}"#
  let settings = try JSONDecoder().decode(PadSettings.self, from: Data(json.utf8))
  #expect(settings.pressure == .init(softness: 0.6, minimum: 0.1, maximum: 0.9))
  #expect(settings.profiles.map(\.name) == ["Default", "Krita", "Photoshop", "Affinity"])
  #expect(settings.profiles[0].gestures.zoomModifier == .alt)
  #expect(settings.profiles[0].gestures.zoomMethod == .nativeGesture)
  #expect(settings.profiles[0].gestures.rotate)
}

@Test func profileMatchesBundlePrefixes() {
  let settings = PadSettings()
  #expect(settings.profile(forAppID: "org.kde.krita").name == "Krita")
  #expect(settings.profile(forAppID: "com.seriflabs.affinityphoto2").name == "Affinity")
  #expect(settings.profile(forAppID: "com.apple.finder").name == "Default")
}

@Test func deletingProfilesKeepsDefault() {
  var settings = PadSettings()
  let defaultID = settings.profiles[0].id
  let deletedDefault = settings.deleteProfile(id: defaultID)
  #expect(!deletedDefault)
  #expect(settings.profiles.count == 4)
  let krita = settings.profiles[1].id
  let deletedKrita = settings.deleteProfile(id: krita)
  #expect(deletedKrita)
  #expect(settings.profiles.map(\.name) == ["Default", "Photoshop", "Affinity"])
  #expect(settings.isDefault(defaultID))
}

@Test func editedButtonPersistsThroughEncodeDecode() throws {
  var settings = PadSettings()
  settings.profiles[1].buttons[0] = .init(
    label: "Redo", chord: .init(key: "KeyY", modifiers: [.primary, .shift]), hold: true)
  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(PadSettings.self, from: data)
  #expect(decoded.profiles[1].buttons[0].label == "Redo")
  #expect(decoded.profiles[1].buttons[0].chord == .init(key: "KeyY", modifiers: [.primary, .shift]))
  #expect(decoded.profiles[1].buttons[0].hold)
}

@Test func buttonsAreCappedAndReorderable() {
  var profile = PadSettings.Profile(name: "P")
  for _ in 0..<PadSettings.maxButtons {
    let added = profile.addButton()
    #expect(added)
  }
  let overflow = profile.addButton()
  #expect(!overflow)
  #expect(profile.buttons.count == 8)
  profile.buttons[0].label = "first"
  profile.moveButton(at: 0, by: 1)
  #expect(profile.buttons[1].label == "first")
  profile.moveButton(at: 7, by: 1)
  #expect(profile.buttons.count == 8)
  profile.moveButton(at: 1, by: -5)
  #expect(profile.buttons[0].label == "first")
}

@Test func newProfileCopiesDefaultAndResetRestoresPresets() {
  var settings = PadSettings(pressure: .firm)
  let id = settings.addProfile()
  #expect(settings.profiles.last?.id == id)
  #expect(settings.profiles.last?.buttons == settings.profiles[0].buttons)
  #expect(settings.profiles.last?.appIDPrefixes == [])
  settings.profiles[0].name = "Mine"
  settings.resetProfilesToPresets()
  #expect(settings.profiles.map(\.name) == ["Default", "Krita", "Photoshop", "Affinity"])
  #expect(settings.pressure == .firm)
}

@Test func emptyAndDefaultPrefixesNeverMatch() {
  var settings = PadSettings()
  settings.profiles[1].appIDPrefixes = ["org.kde.krita", ""]
  #expect(settings.profile(forAppID: "com.apple.finder").name == "Default")
  settings.profiles[0].appIDPrefixes = ["com.apple."]
  settings.profiles[1].appIDPrefixes = []
  #expect(settings.profile(forAppID: "com.apple.finder").name == "Default")
  #expect(settings.profile(forAppID: "org.kde.krita").name == "Default")
}

@Test func edgeBrightnessAllowsFullRangeAndClamps() throws {
  #expect(PadSettings(edgeBrightness: 0.8).edgeBrightness == 0.8)
  #expect(PadSettings(edgeBrightness: 1.5).edgeBrightness == 1)
  let json = #"{"pressure":{"softness":0,"minimum":0,"maximum":1},"edgeBrightness":-2}"#
  #expect(try JSONDecoder().decode(PadSettings.self, from: Data(json.utf8)).edgeBrightness == 0)
}

@Test func v1SettingsMigrateProfilesWithoutLoss() throws {
  let json =
    #"{"pressure":{"softness":0.2,"minimum":0.1,"maximum":0.95},"profiles":[{"id":"11111111-1111-1111-1111-111111111111","name":"Daily","bundleIDPrefixes":["com.example."],"buttons":[{"label":"Undo","chord":{"keyCode":6,"modifiers":["command"]},"hold":false}],"strip":{"mode":"off","side":"right"},"gestures":{"twoFingerScroll":true,"pinchZoom":true,"zoomMethod":"modifierScroll","zoomModifier":"option","rotate":true,"tapUndoRedo":true}}]}"#
  let settings = try JSONDecoder().decode(PadSettings.self, from: Data(json.utf8))
  #expect(settings.pressure == .init(softness: 0.2, minimum: 0.1, maximum: 0.95))
  #expect(settings.profiles[0].buttons[0].chord == .init(key: "KeyZ", modifiers: [.primary]))
  #expect(settings.profiles[0].gestures.zoomModifier == .alt)
  let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
  #expect(!encoded.contains("keyCode") && !encoded.contains("command") && !encoded.contains("option"))
}

@Test func everyPickerKeyHasStableMacMapping() {
  #expect(KeyNames.pickerKeys.allSatisfy { KeyNames.w3cCode(forMacKeyCode: $0.macKeyCode) == $0.code })
}

@Test func resetToDefaultsPreservesPairingIdentityDefaults() {
  let suite = "NibCoreTests.reset"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  defaults.set("device-1", forKey: "nib.deviceID")
  defaults.set("host-1", forKey: "nib.hostPeerID")
  let store = PadSettingsStore(defaults: defaults, key: "settings")
  store.settings.pressure = .firm
  store.settings.edgeBrightness = 0.9
  store.resetToDefaults()
  #expect(store.settings.pressure == .linear)
  #expect(store.settings.edgeBrightness == 0.08)
  #expect(store.settings.profiles.map(\.name) == ["Default", "Krita", "Photoshop", "Affinity"])
  #expect(defaults.string(forKey: "nib.deviceID") == "device-1")
  #expect(defaults.string(forKey: "nib.hostPeerID") == "host-1")
  defaults.removePersistentDomain(forName: suite)
}

@Test func linkStateUsesPlainStatusLines() {
  #expect(PenLinkState.connected(name: "MacBook", viaUSB: true).userFacingText() == "Connected by cable")
  #expect(
    PenLinkState.connected(name: "MacBook", viaUSB: false).userFacingText()
      == "Connected to MacBook over Wi-Fi")
  #expect(PenLinkState.searching.userFacingText() == "Looking for your Mac…")
  #expect(PenLinkState.rejected("busy").userFacingText() == "Your Mac is busy. Try again in a moment.")
}
