#if os(macOS)
  import CoreGraphics

  /// Synthesizes the private Quartz gesture events consumed by AppKit's
  /// magnifyWithEvent:/rotateWithEvent: responders.
  public struct NativeGestureEventBuilder: Sendable {
    public enum Field {
      public static let eventType: CGEventField = CGEventField(rawValue: 55)!
      public static let hidType: CGEventField = CGEventField(rawValue: 110)!
      public static let magnification: CGEventField = CGEventField(rawValue: 113)!
      public static let rotation: CGEventField = CGEventField(rawValue: 114)!
      public static let phase: CGEventField = CGEventField(rawValue: 132)!
    }
    public static let gestureEventType: Int64 = 29
    public static let zoomHIDType: Int64 = 8
    public static let rotationHIDType: Int64 = 5

    private var magnifyActive = false
    private var rotateActive = false

    public init() {}

    public mutating func magnify(delta: Double, phase: Gesture.Phase) -> [CGEvent] {
      let event = make(hidType: Self.zoomHIDType, valueField: Field.magnification, value: delta, phase: phase)
      update(&magnifyActive, phase: phase)
      return [event]
    }

    public mutating func rotate(degrees: Double, phase: Gesture.Phase) -> [CGEvent] {
      let event = make(
        hidType: Self.rotationHIDType, valueField: Field.rotation, value: degrees, phase: phase)
      update(&rotateActive, phase: phase)
      return [event]
    }

    /// Ends any native gesture whose end packet was lost during disconnect.
    public mutating func releaseAll() -> [CGEvent] {
      var events: [CGEvent] = []
      if magnifyActive { events += magnify(delta: 0, phase: .ended) }
      if rotateActive { events += rotate(degrees: 0, phase: .ended) }
      return events
    }

    private func make(
      hidType: Int64, valueField: CGEventField, value: Double, phase: Gesture.Phase
    ) -> CGEvent {
      let event = CGEvent(source: nil)!
      event.type = CGEventType(rawValue: 29)!
      event.setIntegerValueField(Field.eventType, value: Self.gestureEventType)
      event.setIntegerValueField(Field.hidType, value: hidType)
      event.setDoubleValueField(valueField, value: value)
      event.setIntegerValueField(Field.phase, value: phaseValue(phase))
      return event
    }

    private func update(_ active: inout Bool, phase: Gesture.Phase) {
      switch phase {
      case .began: active = true
      case .ended, .cancelled: active = false
      case .changed: break
      }
    }

    private func phaseValue(_ phase: Gesture.Phase) -> Int64 {
      switch phase {
      case .began: 1
      case .changed: 2
      case .ended: 4
      case .cancelled: 8
      }
    }
  }
#endif
