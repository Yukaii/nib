import Foundation
import Testing

@testable import NibCore

@Test func padSettingsRoundTripAndDefaults() throws {
  let settings = PadSettings(
    pressure: .firm, gestures: .init(pinchZoom: false, zoomModifier: .option))
  let data = try JSONEncoder().encode(settings)
  #expect(try JSONDecoder().decode(PadSettings.self, from: data) == settings)
  #expect(PadSettings().pressure == .linear)
  #expect(PadSettings().gestures.tapUndoRedo)
}

@Test func oldSettingsDecodeToPresetsWithoutLosingPressure() throws {
  let json =
    #"{"pressure":{"softness":0.6,"minimum":0.1,"maximum":0.9},"gestures":{"twoFingerScroll":true,"pinchZoom":true,"zoomModifier":"option","tapUndoRedo":true}}"#
  let settings = try JSONDecoder().decode(PadSettings.self, from: Data(json.utf8))
  #expect(settings.pressure == .init(softness: 0.6, minimum: 0.1, maximum: 0.9))
  #expect(settings.profiles.map(\.name) == ["Default", "Krita", "Photoshop", "Affinity"])
  #expect(settings.gestures.zoomModifier == .option)
}

@Test func profileMatchesBundlePrefixes() {
  let settings = PadSettings()
  #expect(settings.profile(forBundleID: "org.kde.krita").name == "Krita")
  #expect(settings.profile(forBundleID: "com.seriflabs.affinityphoto2").name == "Affinity")
  #expect(settings.profile(forBundleID: "com.apple.finder").name == "Default")
}
