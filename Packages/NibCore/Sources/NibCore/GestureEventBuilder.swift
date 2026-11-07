#if os(macOS)
  import CoreGraphics

  /// Converts the wire gesture model into ordered Quartz events.
  ///
  /// Apps such as Krita (Qt) track modifiers from `flagsChanged` key events,
  /// not only from the flags on each event. A modifier that only appears as a
  /// flag is never seen as released, so the app stays in its modifier mode
  /// (Krita: ⌘ → color picker). Every modifier this builder uses is therefore
  /// pressed and released with real `flagsChanged` events, and the builder
  /// remembers a modifier it is holding so it can always release it.
  public struct GestureEventBuilder: Sendable {
    public static let scrollGain: Double = 2
    public static let zoomGain: Double = 400

    /// The modifier held down for an in-progress zoom, if any.
    public private(set) var heldModifier: Gesture.Modifier?

    public init() {}

    public mutating func events(for gesture: Gesture) -> [CGEvent] {
      switch gesture {
      case .scroll(let dx, let dy, let phase):
        let event = scroll(
          horizontal: dx * Self.scrollGain, vertical: dy * Self.scrollGain, phase: phase)
        // Panning never carries a modifier, even while a pinch holds one.
        event.flags = []
        return [event]
      case .zoom(let scaleDelta, let phase, let modifier):
        var events: [CGEvent] = []
        if heldModifier != modifier {
          events += releaseHeldModifier()
          events.append(Self.modifierEvent(modifier, flags: Self.flags(for: modifier)))
          heldModifier = modifier
        }
        let event = scroll(horizontal: 0, vertical: (scaleDelta - 1) * Self.zoomGain, phase: phase)
        event.flags = Self.flags(for: modifier)
        events.append(event)
        if phase == .ended || phase == .cancelled { events += releaseHeldModifier() }
        return events
      case .undo:
        return releaseHeldModifier() + shortcut(zWith: [.command])
      case .redo:
        return releaseHeldModifier() + shortcut(zWith: [.command, .shift])
      }
    }

    /// Releases a held modifier; call before pen input and when the session ends
    /// so a lost "zoom ended" can never leave the app in modifier mode.
    public mutating func releaseHeldModifier() -> [CGEvent] {
      guard let modifier = heldModifier else { return [] }
      heldModifier = nil
      return [Self.modifierEvent(modifier, flags: [])]
    }

    private enum Key { case command, shift }

    private func shortcut(zWith modifiers: [Key]) -> [CGEvent] {
      var flags: CGEventFlags = []
      var events: [CGEvent] = []
      for key in modifiers {
        flags.insert(Self.flags(for: key))
        events.append(Self.keyEvent(Self.keyCode(for: key), type: .flagsChanged, flags: flags))
      }
      events.append(Self.keyEvent(Self.zKey, type: .keyDown, flags: flags))
      events.append(Self.keyEvent(Self.zKey, type: .keyUp, flags: flags))
      for key in modifiers.reversed() {
        flags.remove(Self.flags(for: key))
        events.append(Self.keyEvent(Self.keyCode(for: key), type: .flagsChanged, flags: flags))
      }
      return events
    }

    private func scroll(horizontal: Double, vertical: Double, phase: Gesture.Phase) -> CGEvent {
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: Int32(vertical.rounded()), wheel2: Int32(horizontal.rounded()), wheel3: 0)!
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseValue(phase))
      return event
    }

    // Virtual key codes from HIToolbox Events.h.
    private static let zKey: CGKeyCode = 6

    private static func keyCode(for modifier: Gesture.Modifier) -> CGKeyCode {
      switch modifier {
      case .command: return 55
      case .option: return 58
      case .control: return 59
      }
    }

    private static func keyCode(for key: Key) -> CGKeyCode {
      switch key {
      case .command: return 55
      case .shift: return 56
      }
    }

    private static func flags(for key: Key) -> CGEventFlags {
      switch key {
      case .command: return .maskCommand
      case .shift: return .maskShift
      }
    }

    static func flags(for modifier: Gesture.Modifier) -> CGEventFlags {
      switch modifier {
      case .command: return .maskCommand
      case .option: return .maskAlternate
      case .control: return .maskControl
      }
    }

    private static func modifierEvent(_ modifier: Gesture.Modifier, flags: CGEventFlags) -> CGEvent {
      keyEvent(keyCode(for: modifier), type: .flagsChanged, flags: flags)
    }

    private static func keyEvent(_ code: CGKeyCode, type: CGEventType, flags: CGEventFlags) -> CGEvent {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp)!
      event.type = type
      event.flags = flags
      return event
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
