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
