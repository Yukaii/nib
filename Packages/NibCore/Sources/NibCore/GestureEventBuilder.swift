#if os(macOS)
  import CoreGraphics

  /// Converts the wire gesture model into ordered Quartz events without touching application state.
  public struct GestureEventBuilder: Sendable {
    public static let scrollGain: Double = 2
    public static let zoomGain: Double = 400

    public init() {}

    public func events(for gesture: Gesture) -> [CGEvent] {
      switch gesture {
      case .scroll(let dx, let dy, let phase):
        return [scroll(horizontal: dx * Self.scrollGain, vertical: dy * Self.scrollGain, phase: phase)]
      case .zoom(let scaleDelta, let phase, let modifier):
        let event = scroll(horizontal: 0, vertical: (scaleDelta - 1) * Self.zoomGain, phase: phase)
        event.flags = flags(for: modifier)
        return [event]
      case .undo:
        return keyEvents(modifier: .maskCommand)
      case .redo:
        return keyEvents(modifier: [.maskCommand, .maskShift])
      }
    }

    private func scroll(horizontal: Double, vertical: Double, phase: Gesture.Phase) -> CGEvent {
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: Int32(vertical.rounded()), wheel2: Int32(horizontal.rounded()), wheel3: 0)!
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseValue(phase))
      return event
    }

    private func keyEvents(modifier: CGEventFlags) -> [CGEvent] {
      let down = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true)!
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: false)!
      down.flags = modifier
      up.flags = modifier
      return [down, up]
    }

    private func flags(for modifier: Gesture.Modifier) -> CGEventFlags {
      switch modifier {
      case .command: return .maskCommand
      case .option: return .maskAlternate
      case .control: return .maskControl
      }
    }

    private func phaseValue(_ phase: Gesture.Phase) -> Int64 {
      switch phase {
      case .began: return 1
      case .changed: return 2
      case .ended: return 4
      case .cancelled: return 8
      }
    }
  }
#endif
