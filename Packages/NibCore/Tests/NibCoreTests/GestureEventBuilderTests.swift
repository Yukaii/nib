#if os(macOS)
  import CoreGraphics
  import NibCore
  import Testing

  struct GestureEventBuilderTests {
    @Test func scrollUsesPixelsContinuousAndPhase() {
      let event = GestureEventBuilder().events(for: .scroll(dx: 3, dy: -4, phase: .changed))[0]
      #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -8)
      #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 6)
      #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
      #expect(event.getIntegerValueField(.scrollWheelEventScrollPhase) == 2)
    }

    @Test func zoomUsesModifierAndPinchOutSign() {
      let event = GestureEventBuilder().events(
        for: .zoom(scaleDelta: 1.25, phase: .changed, modifier: .command))[0]
      #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 100)
      #expect(event.flags.contains(.maskCommand))
    }

    @Test func undoRedoAreZKeyPairs() {
      let builder = GestureEventBuilder()
      let undo = builder.events(for: .undo)
      let redo = builder.events(for: .redo)
      #expect(undo.count == 2)
      #expect(redo.count == 2)
      #expect(undo.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 6 })
      #expect(redo.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 6 })
      #expect(undo.allSatisfy { $0.flags.contains(.maskCommand) && !$0.flags.contains(.maskShift) })
      #expect(redo.allSatisfy { $0.flags.contains(.maskCommand) && $0.flags.contains(.maskShift) })
    }
  }
#endif
