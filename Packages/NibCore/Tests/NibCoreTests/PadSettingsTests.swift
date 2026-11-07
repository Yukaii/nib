import Foundation
import Testing

@testable import NibCore

@Test func padSettingsRoundTripAndDefaults() throws {
  let settings = PadSettings(
    pressure: .firm, gestures: .init(pinchZoom: false, zoomModifier: .option))
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
  #expect(settings.profiles[0].gestures.zoomModifier == .option)
}

@Test func profileMatchesBundlePrefixes() {
  let settings = PadSettings()
  #expect(settings.profile(forBundleID: "org.kde.krita").name == "Krita")
  #expect(settings.profile(forBundleID: "com.seriflabs.affinityphoto2").name == "Affinity")
  #expect(settings.profile(forBundleID: "com.apple.finder").name == "Default")
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
    label: "Redo", chord: .init(keyCode: 16, modifiers: [.command, .shift]), hold: true)
  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(PadSettings.self, from: data)
  #expect(decoded.profiles[1].buttons[0].label == "Redo")
  #expect(decoded.profiles[1].buttons[0].chord == .init(keyCode: 16, modifiers: [.command, .shift]))
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
  #expect(settings.profiles.last?.bundleIDPrefixes == [])
  settings.profiles[0].name = "Mine"
  settings.resetProfilesToPresets()
  #expect(settings.profiles.map(\.name) == ["Default", "Krita", "Photoshop", "Affinity"])
  #expect(settings.pressure == .firm)
}

@Test func emptyAndDefaultPrefixesNeverMatch() {
  var settings = PadSettings()
  settings.profiles[1].bundleIDPrefixes = ["org.kde.krita", ""]
  #expect(settings.profile(forBundleID: "com.apple.finder").name == "Default")
  settings.profiles[0].bundleIDPrefixes = ["com.apple."]
  settings.profiles[1].bundleIDPrefixes = []
  #expect(settings.profile(forBundleID: "com.apple.finder").name == "Default")
  #expect(settings.profile(forBundleID: "org.kde.krita").name == "Default")
}

@Test func edgeBrightnessAllowsFullRangeAndClamps() throws {
  #expect(PadSettings(edgeBrightness: 0.8).edgeBrightness == 0.8)
  #expect(PadSettings(edgeBrightness: 1.5).edgeBrightness == 1)
  let json = #"{"pressure":{"softness":0,"minimum":0,"maximum":1},"edgeBrightness":-2}"#
  #expect(try JSONDecoder().decode(PadSettings.self, from: Data(json.utf8)).edgeBrightness == 0)
}
