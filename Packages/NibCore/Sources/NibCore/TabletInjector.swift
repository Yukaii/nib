#if os(macOS)
  import ApplicationServices
  import CoreGraphics

  public struct TabletInjector {
    public init() {}

    public static var isTrusted: Bool {
      AXIsProcessTrusted()
    }

    public func post(_ events: [CGEvent]) {
      for event in events {
        event.post(tap: .cghidEventTap)
      }
    }

    public func post(sample: PenSample, at point: CGPoint, using builder: inout TabletEventBuilder) {
      post(builder.events(for: sample, at: point))
    }
  }
#endif
