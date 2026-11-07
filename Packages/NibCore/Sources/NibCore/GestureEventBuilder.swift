#if os(macOS)
  import CoreGraphics
  import os

  private let gestureEventLogger = Logger(subsystem: "dev.yukai.nib", category: "gesture")

  /// Converts the wire gesture model into ordered Quartz events.
  ///
  /// Apps such as Krita (Qt) track modifiers from `flagsChanged` key events,
  /// not only from the flags on each event. A modifier that only appears as a
  /// flag is never seen as released, so the app stays in its modifier mode
  /// (Krita: ⌘ → color picker). Every modifier this builder uses is therefore
  /// pressed and released with real `flagsChanged` events, and the builder
  /// remembers modifiers and chords it is holding so it can always release them.
  public struct GestureEventBuilder: Sendable {
    public static let scrollGain: Double = 2
    public static let zoomGain: Double = 400
    /// The modifier held down for an in-progress zoom, if any.
    public private(set) var heldModifier: Gesture.Modifier?
    private var heldChords: [Gesture.KeyChord] = []
    private var heldFlags: CGEventFlags = []
    private var nativeBuilder = NativeGestureEventBuilder()
    public init() {}

    public mutating func events(for gesture: Gesture) -> [CGEvent] {
      switch gesture {
      case .scroll(let dx, let dy, let phase):
        let event = scroll(horizontal: dx * Self.scrollGain, vertical: dy * Self.scrollGain, phase: phase)
        // Panning never carries a modifier, even while a pinch holds one.
        event.flags = []
        return [event]
      case .zoom(let delta, let phase, let modifier, let method):
        if method == .nativeGesture {
          return releaseHeldModifier() + nativeBuilder.magnify(delta: delta - 1, phase: phase)
        }
        var events = releaseHeldModifierIfNeeded(except: modifier)
        if heldModifier != modifier {
          events.append(Self.modifierEvent(modifier, flags: Self.flags(for: modifier)))
          heldModifier = modifier
        }
        let event = scroll(horizontal: 0, vertical: (delta - 1) * Self.zoomGain, phase: phase)
        event.flags = Self.flags(for: modifier)
        events.append(event)
        if phase == .ended || phase == .cancelled { events += releaseHeldModifier() }
        return events
      case .rotate(let degrees, let phase):
        return releaseHeldModifier() + nativeBuilder.rotate(degrees: degrees, phase: phase)
      case .undo:
        return releaseHeldModifier() + shortcut(.init(key: "KeyZ", modifiers: [.primary]), action: .tap)
      case .redo:
        return releaseHeldModifier()
          + shortcut(.init(key: "KeyZ", modifiers: [.primary, .shift]), action: .tap)
      case .key(let chord, let action): return releaseHeldModifier() + shortcut(chord, action: action)
      }
    }

    /// Releases the modifier held by an in-progress zoom.
    public mutating func releaseHeldModifier() -> [CGEvent] {
      guard let modifier = heldModifier else { return [] }
      heldModifier = nil
      return [Self.modifierEvent(modifier, flags: [])]
    }
    /// Releases all held shortcut chords and zoom state; call at session end only.
    public mutating func releaseAll() -> [CGEvent] {
      var events: [CGEvent] = []
      for chord in heldChords.reversed() {
        if let keyCode = chord.key.flatMap({ KeyNames.key(for: $0)?.macKeyCode }) {
          events.append(Self.keyEvent(CGKeyCode(keyCode), type: .keyUp, flags: heldFlags))
        }
      }
      heldChords.removeAll()
      for modifier in modifierOrder.reversed() where heldFlags.contains(Self.flags(for: modifier)) {
        heldFlags.remove(Self.flags(for: modifier))
        events.append(Self.modifierEvent(modifier, flags: heldFlags))
      }
      events += releaseHeldModifier()
      events += nativeBuilder.releaseAll()
      return events
    }

    private let modifierOrder: [Gesture.Modifier] = [.primary, .meta, .alt, .control, .shift]
    private mutating func shortcut(_ chord: Gesture.KeyChord, action: Gesture.KeyAction) -> [CGEvent] {
      if let key = chord.key, KeyNames.key(for: key) == nil {
        gestureEventLogger.info("Ignoring unmapped key code \(key, privacy: .public)")
        return []
      }
      switch action {
      case .tap:
        let pressedModifiers = chord.modifiers.subtracting(heldFlagsToModifiers)
        var events = pressModifiers(pressedModifiers)
        if let keyCode = chord.key.flatMap({ KeyNames.key(for: $0)?.macKeyCode }) {
          events.append(Self.keyEvent(CGKeyCode(keyCode), type: .keyDown, flags: heldFlags))
          events.append(Self.keyEvent(CGKeyCode(keyCode), type: .keyUp, flags: heldFlags))
        }
        events += releaseModifiers(pressedModifiers)
        return events
      case .down:
        var events = pressModifiers(chord.modifiers)
        if let keyCode = chord.key.flatMap({ KeyNames.key(for: $0)?.macKeyCode }) {
          events.append(Self.keyEvent(CGKeyCode(keyCode), type: .keyDown, flags: heldFlags))
        }
        heldChords.append(chord)
        return events
      case .up:
        guard let index = heldChords.lastIndex(of: chord) else { return [] }
        heldChords.remove(at: index)
        var events: [CGEvent] = []
        if let keyCode = chord.key.flatMap({ KeyNames.key(for: $0)?.macKeyCode }) {
          events.append(Self.keyEvent(CGKeyCode(keyCode), type: .keyUp, flags: heldFlags))
        }
        let remaining = Set(heldChords.flatMap(\.modifiers))
        events += releaseModifiers(chord.modifiers.subtracting(remaining))
        return events
      }
    }
    private var heldFlagsToModifiers: Set<Gesture.Modifier> {
      Set(modifierOrder.filter { heldFlags.contains(Self.flags(for: $0)) })
    }
    private mutating func pressModifiers(_ modifiers: Set<Gesture.Modifier>) -> [CGEvent] {
      var result: [CGEvent] = []
      for modifier in modifierOrder
      where modifiers.contains(modifier) && !heldFlags.contains(Self.flags(for: modifier)) {
        heldFlags.insert(Self.flags(for: modifier))
        result.append(Self.modifierEvent(modifier, flags: heldFlags))
      }
      return result
    }
    private mutating func releaseModifiers(_ modifiers: Set<Gesture.Modifier>) -> [CGEvent] {
      var result: [CGEvent] = []
      for modifier in modifierOrder.reversed()
      where modifiers.contains(modifier) && heldFlags.contains(Self.flags(for: modifier)) {
        heldFlags.remove(Self.flags(for: modifier))
        result.append(Self.modifierEvent(modifier, flags: heldFlags))
      }
      return result
    }
    private mutating func releaseHeldModifierIfNeeded(except modifier: Gesture.Modifier) -> [CGEvent] {
      heldModifier == modifier ? [] : releaseHeldModifier()
    }
    private func scroll(horizontal: Double, vertical: Double, phase: Gesture.Phase) -> CGEvent {
      let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(vertical.rounded()),
        wheel2: Int32(horizontal.rounded()), wheel3: 0)!
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseValue(phase))
      return event
    }
    private static func flags(for modifier: Gesture.Modifier) -> CGEventFlags {
      switch modifier {
      case .primary, .meta: return .maskCommand
      case .alt: return .maskAlternate
      case .control: return .maskControl
      case .shift: return .maskShift
      }
    }
    private static func modifierEvent(_ modifier: Gesture.Modifier, flags: CGEventFlags) -> CGEvent {
      keyEvent(keyCode(for: modifier), type: .flagsChanged, flags: flags)
    }
    private static func keyCode(for modifier: Gesture.Modifier) -> CGKeyCode {
      switch modifier {
      case .primary, .meta: return 55
      case .alt: return 58
      case .control: return 59
      case .shift: return 56
      }
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
