#if os(macOS)
  import CoreGraphics
  import NibCore
  import Testing

  struct GestureEventBuilderTests {
    private func keyCode(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.keyboardEventKeycode) }

    @Test func scrollUsesPixelsContinuousAndPhase() {
      var builder = GestureEventBuilder()
      let event = builder.events(for: .scroll(dx: 3, dy: -4, phase: .changed))[0]
      #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -8)
      #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 6)
      #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
      #expect(event.getIntegerValueField(.scrollWheelEventScrollPhase) == 2)
      #expect(event.flags.isEmpty)
    }

    @Test func zoomPressesModifierOnceAndReleasesOnEnd() {
      var builder = GestureEventBuilder()
      let began = builder.events(for: .zoom(scaleDelta: 1.25, phase: .began, modifier: .command))
      #expect(began.map(\.type) == [.flagsChanged, .scrollWheel])
      #expect(keyCode(began[0]) == 55 && began[0].flags.contains(.maskCommand))
      #expect(began[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 100)
      #expect(began[1].flags.contains(.maskCommand))

      let changed = builder.events(for: .zoom(scaleDelta: 1.1, phase: .changed, modifier: .command))
      #expect(changed.map(\.type) == [.scrollWheel])

      // Panning during a pinch stays a plain scroll.
      #expect(builder.events(for: .scroll(dx: 1, dy: 1, phase: .changed))[0].flags.isEmpty)

      let ended = builder.events(for: .zoom(scaleDelta: 1, phase: .ended, modifier: .command))
      #expect(ended.map(\.type) == [.scrollWheel, .flagsChanged])
      #expect(keyCode(ended[1]) == 55 && ended[1].flags.isEmpty)
      #expect(builder.heldModifier == nil)
    }

    @Test func lostZoomEndIsReleasedExplicitly() {
      var builder = GestureEventBuilder()
      _ = builder.events(for: .zoom(scaleDelta: 1.2, phase: .began, modifier: .option))
      let release = builder.releaseHeldModifier()
      #expect(release.count == 1 && keyCode(release[0]) == 58 && release[0].flags.isEmpty)
      #expect(builder.releaseHeldModifier().isEmpty)
    }

    @Test func undoRedoPressAndReleaseModifiers() {
      var builder = GestureEventBuilder()
      let undo = builder.events(for: .undo)
      #expect(undo.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
      #expect(undo.map { keyCode($0) } == [55, 6, 6, 55])
      #expect(undo[1].flags == .maskCommand && undo[3].flags.isEmpty)

      let redo = builder.events(for: .redo)
      #expect(redo.map { keyCode($0) } == [55, 56, 6, 6, 56, 55])
      #expect(redo[2].flags.contains([.maskCommand, .maskShift]))
      #expect(redo.last!.flags.isEmpty)
    }

    @Test func undoDuringZoomReleasesZoomModifierFirst() {
      var builder = GestureEventBuilder()
      _ = builder.events(for: .zoom(scaleDelta: 1.2, phase: .began, modifier: .control))
      let undo = builder.events(for: .undo)
      #expect(keyCode(undo[0]) == 59 && undo[0].flags.isEmpty)
      #expect(builder.heldModifier == nil)
    }
  }
#endif
