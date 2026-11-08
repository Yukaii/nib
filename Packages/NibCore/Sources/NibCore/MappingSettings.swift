import CoreGraphics

/// The host-owned choices that determine where Pencil samples land on a Mac.
public struct MappingSettings: Codable, Equatable, Sendable {
  public enum Target: Codable, Equatable, Sendable {
    case display(uuid: String)
    case allDisplays
  }

  public enum Proportions: String, Codable, Equatable, Sendable {
    case keep
    case stretch
  }

  public struct Area: Codable, Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 1, height: CGFloat = 1) {
      self.x = min(0.9, max(0, x))
      self.y = min(0.9, max(0, y))
      self.width = min(1 - self.x, max(0.1, width))
      self.height = min(1 - self.y, max(0.1, height))
    }

    public static let whole = Area()

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  }

  public var target: Target
  public var area: Area
  public var proportions: Proportions

  public init(
    target: Target = .allDisplays, area: Area = .whole, proportions: Proportions = .keep
  ) {
    self.target = target
    self.area = area
    self.proportions = proportions
  }

  public struct Display: Equatable, Sendable {
    public let uuid: String
    public let bounds: CGRect

    public init(uuid: String, bounds: CGRect) {
      self.uuid = uuid
      self.bounds = bounds
    }
  }

  public struct Resolution: Equatable, Sendable {
    public let rect: CGRect
    public let usedFallback: Bool

    public init(rect: CGRect, usedFallback: Bool) {
      self.rect = rect
      self.usedFallback = usedFallback
    }
  }

  /// Resolves a saved target without depending on AppKit. A missing display uses the main display
  /// until the saved UUID appears again.
  public func resolve(displays: [Display], mainUUID: String) -> Resolution? {
    guard !displays.isEmpty else { return nil }
    let base: CGRect
    let fallback: Bool
    switch target {
    case .allDisplays:
      base = displays.dropFirst().reduce(displays[0].bounds) { $0.union($1.bounds) }
      fallback = false
    case .display(let uuid):
      if let display = displays.first(where: { $0.uuid == uuid }) {
        base = display.bounds
        fallback = false
      } else if let main = displays.first(where: { $0.uuid == mainUUID }) {
        base = main.bounds
        fallback = true
      } else {
        base = displays[0].bounds
        fallback = true
      }
    }
    let rect = CGRect(
      x: base.minX + area.x * base.width,
      y: base.minY + area.y * base.height,
      width: area.width * base.width,
      height: area.height * base.height)
    return Resolution(rect: rect, usedFallback: fallback)
  }
}
