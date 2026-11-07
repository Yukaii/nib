import Foundation
import Observation

@Observable
public final class PadSettingsStore: @unchecked Sendable {
  public var settings: PadSettings { didSet { save() } }
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "nib.padSettings") {
    self.defaults = defaults
    self.key = key
    if let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode(PadSettings.self, from: data)
    {
      settings = decoded
    } else {
      settings = PadSettings()
    }
  }

  public func save() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: key)
  }
}
