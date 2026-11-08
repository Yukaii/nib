import CoreGraphics

/// The host-owned choices that determine where Pencil samples land on a Mac.
public struct MappingSettings: Codable, Equatable, Sendable {
  public enum Target: Codable, Equatable, Sendable {
    case followMain
    case display(uuid: String)
    case allDisplays

    private enum CodingKeys: String, CodingKey { case kind, uuid, display, allDisplays }
    private enum Kind: String, Codable { case followMain, display, allDisplays }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let legacy = try container.decodeIfPresent([String: String].self, forKey: .display),
        let uuid = legacy["uuid"]
      {
        self = .display(uuid: uuid)
        return
      }
      if container.contains(.allDisplays) {
        self = .allDisplays
        return
      }
      let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .followMain
      switch kind {
      case .followMain: self = .followMain
      case .allDisplays: self = .allDisplays
      case .display:
        let uuid = try container.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        let legacyDisplayID = uuid.dropFirst("display-".count)
        self =
          uuid.hasPrefix("display-") && !legacyDisplayID.isEmpty
            && legacyDisplayID.allSatisfy(\.isNumber) ? .followMain : .display(uuid: uuid)
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .followMain: try container.encode(Kind.followMain, forKey: .kind)
      case .allDisplays: try container.encode(Kind.allDisplays, forKey: .kind)
      case .display(let uuid):
        try container.encode(Kind.display, forKey: .kind)
        try container.encode(uuid, forKey: .uuid)
      }
    }
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
      let clampedWidth = min(1, max(0.1, width))
      let clampedHeight = min(1, max(0.1, height))
      self.width = clampedWidth
      self.height = clampedHeight
      self.x = min(1 - clampedWidth, max(0, x))
      self.y = min(1 - clampedHeight, max(0, y))
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        x: (try? container.decodeIfPresent(CGFloat.self, forKey: .x)) ?? 0,
        y: (try? container.decodeIfPresent(CGFloat.self, forKey: .y)) ?? 0,
        width: (try? container.decodeIfPresent(CGFloat.self, forKey: .width)) ?? 1,
        height: (try? container.decodeIfPresent(CGFloat.self, forKey: .height)) ?? 1)
    }

    public static let whole = Area()

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }
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

  private enum CodingKeys: String, CodingKey { case target, area, proportions }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      target: (try? container.decodeIfPresent(Target.self, forKey: .target)) ?? .followMain,
      area: (try? container.decodeIfPresent(Area.self, forKey: .area)) ?? .whole,
      proportions: (try? container.decodeIfPresent(Proportions.self, forKey: .proportions)) ?? .keep)
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

  public func resolveBaseRect(displays: [Display], mainUUID: String) -> Resolution? {
    guard !displays.isEmpty else { return nil }
    switch target {
    case .allDisplays:
      return Resolution(
        rect: displays.dropFirst().reduce(displays[0].bounds) { $0.union($1.bounds) }, usedFallback: false)
    case .followMain:
      if let main = displays.first(where: { $0.uuid == mainUUID }) {
        return Resolution(rect: main.bounds, usedFallback: false)
      }
      return Resolution(rect: displays[0].bounds, usedFallback: true)
    case .display(let uuid):
      if let display = displays.first(where: { $0.uuid == uuid }) {
        return Resolution(rect: display.bounds, usedFallback: false)
      }
      if let main = displays.first(where: { $0.uuid == mainUUID }) {
        return Resolution(rect: main.bounds, usedFallback: true)
      }
      return Resolution(rect: displays[0].bounds, usedFallback: true)
    }
  }

  /// Resolves a saved target without depending on AppKit. A missing display uses the main display
  /// until the saved UUID appears again.
  public func resolve(displays: [Display], mainUUID: String) -> Resolution? {
    guard !displays.isEmpty else { return nil }
    guard let baseResolution = resolveBaseRect(displays: displays, mainUUID: mainUUID) else { return nil }
    let base = baseResolution.rect
    let rect = CGRect(
      x: base.minX + area.x * base.width,
      y: base.minY + area.y * base.height,
      width: area.width * base.width,
      height: area.height * base.height)
    return Resolution(rect: rect, usedFallback: baseResolution.usedFallback)
  }

  /// Converts an active area to a scaled preview rectangle inside the selected base.
  public static func previewRect(for area: Area, in previewBaseRect: CGRect) -> CGRect {
    CGRect(
      x: previewBaseRect.minX + area.x * previewBaseRect.width,
      y: previewBaseRect.minY + area.y * previewBaseRect.height,
      width: area.width * previewBaseRect.width,
      height: area.height * previewBaseRect.height)
  }

  /// Converts a preview rectangle back to a clamped normalized active area.
  public static func area(from previewRect: CGRect, in previewBaseRect: CGRect) -> Area {
    guard previewBaseRect.width > 0, previewBaseRect.height > 0 else { return .whole }
    return Area(
      x: (previewRect.minX - previewBaseRect.minX) / previewBaseRect.width,
      y: (previewRect.minY - previewBaseRect.minY) / previewBaseRect.height,
      width: previewRect.width / previewBaseRect.width,
      height: previewRect.height / previewBaseRect.height)
  }
}
