#if os(macOS)
  import AppKit
  import CoreGraphics

  /// Connects received samples to the tablet event builder and Quartz poster.
  public struct PenInjectionController {
    public private(set) var mapper: DisplayMapper
    public private(set) var accessibilityTrusted = false

    private var builder = TabletEventBuilder()
    private let post: ([CGEvent]) -> Void
    private let trust: () -> Bool

    public init(
      surfaceSize: CGSize = .zero, displayRect: CGRect = .zero,
      post: @escaping ([CGEvent]) -> Void,
      isTrusted: @escaping () -> Bool = { TabletInjector.isTrusted }
    ) {
      mapper = DisplayMapper(surfaceSize: surfaceSize, displayRect: displayRect)
      self.post = post
      trust = isTrusted
    }

    @discardableResult
    public mutating func handle(_ sample: PenSample) -> Bool {
      accessibilityTrusted = trust()
      guard accessibilityTrusted else { return false }
      let events = builder.events(for: sample, at: mapper.map(sample))
      guard !events.isEmpty else { return true }
      post(events)
      return true
    }

    public mutating func surfaceChanged(_ size: CGSize) {
      mapper.surfaceChanged(size)
    }

    public mutating func displayChanged(_ rect: CGRect) {
      mapper.displayChanged(rect)
    }

    public mutating func sessionEnded() {
      accessibilityTrusted = trust()
      guard accessibilityTrusted else { return }
      let sample = PenSample(
        kind: .proximityExit, sequence: 0, timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0,
        azimuth: 0)
      let events = builder.events(for: sample, at: mapper.map(sample))
      if !events.isEmpty { post(events) }
    }
  }
#endif
