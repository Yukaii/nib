import Foundation
import Testing

@testable import NibCore

@Test func pressureCurveEndpointsAndRange() {
  for preset in [
    PadSettings.Pressure.soft, .linear, .firm, .init(softness: -1, minimum: 0.2, maximum: 0.8),
    .init(softness: 1, minimum: 0, maximum: 1),
  ] {
    #expect(PressureCurve.apply(0, preset) >= 0 && PressureCurve.apply(0, preset) <= 1)
    #expect(PressureCurve.apply(1, preset) == 1)
    for index in 0...100 {
      let value = PressureCurve.apply(Float(index) / 100, preset)
      #expect(value >= 0 && value <= 1)
      if index > 0 { #expect(value >= PressureCurve.apply(Float(index - 1) / 100, preset)) }
    }
  }
}

@Test func pressureCurveThresholds() {
  let pressure = PadSettings.Pressure(softness: 0, minimum: 0.2, maximum: 0.8)
  #expect(PressureCurve.apply(0.19, pressure) == 0)
  #expect(abs(PressureCurve.apply(0.5, pressure) - 0.5) < 0.001)
  #expect(PressureCurve.apply(0.8, pressure) == 1)
}

@Test func padSettingsStoreRoundTripsUserDefaults() {
  let suite = "NibCoreTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = PadSettingsStore(defaults: defaults)
  store.settings = PadSettings(pressure: .firm, gestures: .init(pinchZoom: false, zoomModifier: .alt))
  let reloaded = PadSettingsStore(defaults: defaults)
  #expect(reloaded.settings == store.settings)
}
