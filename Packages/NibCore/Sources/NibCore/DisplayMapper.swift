import CoreGraphics

/// Maps normalized iPad coordinates onto a display while preserving its aspect ratio.
public struct DisplayMapper: Sendable, Equatable {
  public private(set) var surfaceSize: CGSize
  public private(set) var displayRect: CGRect
  public private(set) var proportions: MappingSettings.Proportions
  public private(set) var edgeMargin: CGFloat

  public init(
    surfaceSize: CGSize = .zero, displayRect: CGRect = .zero,
    proportions: MappingSettings.Proportions = .keep, edgeMargin: CGFloat = 0
  ) {
    self.surfaceSize = surfaceSize
    self.displayRect = displayRect
    self.proportions = proportions
    self.edgeMargin = min(0.15, max(0, edgeMargin))
  }

  public mutating func surfaceChanged(_ size: CGSize) { surfaceSize = size }
  public mutating func mappingChanged(
    _ rect: CGRect, proportions: MappingSettings.Proportions, edgeMargin: CGFloat = 0
  ) {
    displayRect = rect
    self.proportions = proportions
    self.edgeMargin = min(0.15, max(0, edgeMargin))
  }

  public func map(_ sample: PenSample) -> CGPoint {
    guard displayRect.width > 0, displayRect.height > 0 else { return displayRect.origin }
    let margin = edgeMargin
    let scale = 1 - 2 * margin
    let x = min(1, max(0, (CGFloat(sample.x) - margin) / scale))
    let y = min(1, max(0, (CGFloat(sample.y) - margin) / scale))
    guard surfaceSize.width > 0, surfaceSize.height > 0 else {
      return point(x: x, y: y)
    }

    guard proportions == .keep else { return point(x: x, y: y) }
    let surfaceAspect = surfaceSize.width / surfaceSize.height
    let displayAspect = displayRect.width / displayRect.height
    let activeSize: CGSize
    if surfaceAspect > displayAspect {
      activeSize = CGSize(width: surfaceSize.height * displayAspect, height: surfaceSize.height)
    } else {
      activeSize = CGSize(width: surfaceSize.width, height: surfaceSize.width / displayAspect)
    }
    let activeOrigin = CGPoint(
      x: (surfaceSize.width - activeSize.width) / 2,
      y: (surfaceSize.height - activeSize.height) / 2)
    let activeX = (x * surfaceSize.width - activeOrigin.x) / activeSize.width
    let activeY = (y * surfaceSize.height - activeOrigin.y) / activeSize.height
    return point(x: activeX, y: activeY)
  }

  private func point(x: CGFloat, y: CGFloat) -> CGPoint {
    CGPoint(
      x: displayRect.minX + min(1, max(0, x)) * max(0, displayRect.width.nextDown),
      y: displayRect.minY + min(1, max(0, y)) * max(0, displayRect.height.nextDown))
  }
}
