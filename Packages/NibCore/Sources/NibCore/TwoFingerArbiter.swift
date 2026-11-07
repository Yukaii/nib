import Foundation

/// Decides what a two-finger gesture means before anything reaches the Mac.
///
/// A twist always moves the fingers' centroid a little, so sending scroll,
/// zoom and rotate together makes the scroll win: Mac apps handle one
/// trackpad gesture at a time. Like a trackpad, the gesture stays undecided
/// until one component clearly dominates (each measured against its own
/// threshold), then locks to either scrolling or zoom+rotate. A scroll can
/// still escalate to zoom+rotate on a deliberate twist or pinch; zoom+rotate
/// never falls back to scrolling.
public struct TwoFingerArbiter: Sendable, Equatable {
  public enum Mode: Sendable, Equatable { case undecided, pan, transform }

  public struct Thresholds: Sendable, Equatable {
    /// Centroid travel in points.
    public var pan: Double = 18
    /// |ln(scale)|: 0.06 ≈ 6 %.
    public var zoom: Double = 0.06
    /// Degrees.
    public var rotate: Double = 6
    /// A scroll escalates to zoom+rotate past these.
    public var escalateZoom: Double = 0.25
    public var escalateRotate: Double = 20
    public init() {}
  }

  public var thresholds: Thresholds
  public var panEnabled: Bool
  public var zoomEnabled: Bool
  public var rotateEnabled: Bool

  public private(set) var mode = Mode.undecided
  /// Within `.transform`, each component starts once it passes its own
  /// threshold, so a pure pinch does not wobble the canvas's rotation.
  public private(set) var zoomEngaged = false
  public private(set) var rotateEngaged = false
  /// Totals since the gesture began, for catching up when a component engages.
  public private(set) var translationX: Double = 0
  public private(set) var translationY: Double = 0
  public private(set) var logScale: Double = 0
  public private(set) var rotationDegrees: Double = 0

  public init(
    thresholds: Thresholds = Thresholds(), panEnabled: Bool = true, zoomEnabled: Bool = true,
    rotateEnabled: Bool = true
  ) {
    self.thresholds = thresholds
    self.panEnabled = panEnabled
    self.zoomEnabled = zoomEnabled
    self.rotateEnabled = rotateEnabled
  }

  /// Adds one update's deltas. `scale` is a multiplicative factor (1 = none).
  public mutating func add(
    dx: Double = 0, dy: Double = 0, scale: Double = 1, rotationDegrees degrees: Double = 0
  ) {
    if dx.isFinite { translationX += dx }
    if dy.isFinite { translationY += dy }
    if scale.isFinite, scale > 0 { logScale += Foundation.log(scale) }
    if degrees.isFinite { rotationDegrees += degrees }

    let pan = panEnabled ? hypot(translationX, translationY) / thresholds.pan : 0
    let zoom = zoomEnabled ? abs(logScale) / thresholds.zoom : 0
    let rotate = rotateEnabled ? abs(rotationDegrees) / thresholds.rotate : 0

    switch mode {
    case .undecided:
      guard max(pan, zoom, rotate) >= 1 else { return }
      mode = pan > max(zoom, rotate) ? .pan : .transform
    case .pan:
      let twist = rotateEnabled && abs(rotationDegrees) >= thresholds.escalateRotate
      let pinch = zoomEnabled && abs(logScale) >= thresholds.escalateZoom
      if twist || pinch { mode = .transform }
    case .transform:
      break
    }
    if mode == .transform {
      if zoom >= 1 { zoomEngaged = true }
      if rotate >= 1 { rotateEngaged = true }
    }
  }

  public mutating func reset() {
    self = TwoFingerArbiter(
      thresholds: thresholds, panEnabled: panEnabled, zoomEnabled: zoomEnabled,
      rotateEnabled: rotateEnabled)
  }
}
