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

    @Test func nativeMagnifyAndRotateUsePrivateGestureFields() {
      var native = NativeGestureEventBuilder()
      let magnify = native.magnify(delta: 0.25, phase: .changed)[0]
      #expect(magnify.type.rawValue == 29)
      #expect(magnify.getIntegerValueField(NativeGestureEventBuilder.Field.eventType) == 29)
      #expect(magnify.getIntegerValueField(NativeGestureEventBuilder.Field.hidType) == 8)
      #expect(magnify.getDoubleValueField(NativeGestureEventBuilder.Field.magnification) == 0.25)
      #expect(magnify.getIntegerValueField(NativeGestureEventBuilder.Field.phase) == 2)
      let rotate = native.rotate(degrees: 45, phase: .began)[0]
      #expect(rotate.getIntegerValueField(NativeGestureEventBuilder.Field.hidType) == 5)
      #expect(rotate.getDoubleValueField(NativeGestureEventBuilder.Field.rotation) == 45)
      #expect(rotate.getIntegerValueField(NativeGestureEventBuilder.Field.phase) == 1)
      _ = native.rotate(degrees: 1, phase: .changed)
      #expect(native.releaseAll().last?.getIntegerValueField(NativeGestureEventBuilder.Field.phase) == 4)
    }

    @Test func zoomPressesModifierOnceAndReleasesOnEnd() {
      var builder = GestureEventBuilder()
      let began = builder.events(
        for: .zoom(scaleDelta: 1.25, phase: .began, modifier: .command))
      #expect(began.map(\.type) == [.flagsChanged, .scrollWheel])
      #expect(keyCode(began[0]) == 55 && began[0].flags.contains(.maskCommand))
      #expect(began[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 100)
      #expect(began[1].flags.contains(.maskCommand))

      let changed = builder.events(
        for: .zoom(scaleDelta: 1.1, phase: .changed, modifier: .command))
      #expect(changed.map(\.type) == [.scrollWheel])

      // Panning during a pinch stays a plain scroll.
      #expect(builder.events(for: .scroll(dx: 1, dy: 1, phase: .changed))[0].flags.isEmpty)

      let ended = builder.events(
        for: .zoom(scaleDelta: 1, phase: .ended, modifier: .command))
      #expect(ended.map(\.type) == [.scrollWheel, .flagsChanged])
      #expect(keyCode(ended[1]) == 55 && ended[1].flags.isEmpty)
      #expect(builder.heldModifier == nil)
    }

    @Test func lostZoomEndIsReleasedExplicitly() {
      var builder = GestureEventBuilder()
      _ = builder.events(
        for: .zoom(scaleDelta: 1.2, phase: .began, modifier: .option))
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

    @Test func tapShiftCommandZUsesCumulativeModifierFlags() {
      var builder = GestureEventBuilder()
      let events = builder.events(
        for: .key(.init(keyCode: 6, modifiers: [.shift, .command]), action: .tap))
      #expect(
        events.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
      #expect(events.map { keyCode($0) } == [55, 56, 6, 6, 56, 55])
      #expect(events[0].flags == .maskCommand)
      #expect(events[1].flags == [.maskCommand, .maskShift])
      #expect(events[2].flags == [.maskCommand, .maskShift])
      #expect(events[3].flags == [.maskCommand, .maskShift])
      #expect(events[4].flags == .maskCommand)
      #expect(events[5].flags.isEmpty)
    }

    @Test func releaseAllReleasesHeldKeyAndModifierOnlyChord() {
      var builder = GestureEventBuilder()
      _ = builder.events(for: .key(.init(keyCode: 49), action: .down))
      let keyRelease = builder.releaseAll()
      #expect(keyRelease.map(\.type) == [.keyUp])
      #expect(keyCode(keyRelease[0]) == 49)

      _ = builder.events(for: .key(.init(modifiers: [.option]), action: .down))
      let modifierRelease = builder.releaseAll()
      #expect(modifierRelease.map(\.type) == [.flagsChanged])
      #expect(keyCode(modifierRelease[0]) == 58)
      #expect(modifierRelease[0].flags.isEmpty)
    }

    @Test func tapDoesNotReleaseModifierHeldByAnotherChord() {
      var builder = GestureEventBuilder()
      let held = Gesture.KeyChord(keyCode: 49, modifiers: [.shift])
      _ = builder.events(for: .key(held, action: .down))
      let tap = builder.events(
        for: .key(.init(keyCode: 6, modifiers: [.shift, .command]), action: .tap))
      #expect(tap.map { keyCode($0) } == [55, 6, 6, 55])
      #expect(tap.last!.flags == .maskShift)
      let end = builder.releaseAll()
      #expect(end.map { keyCode($0) } == [49, 56])
      #expect(end.last!.flags.isEmpty)
    }

    @Test func undoDuringZoomReleasesZoomModifierFirst() {
      var builder = GestureEventBuilder()
      _ = builder.events(
        for: .zoom(scaleDelta: 1.2, phase: .began, modifier: .control))
      let undo = builder.events(for: .undo)
      #expect(keyCode(undo[0]) == 59 && undo[0].flags.isEmpty)
      #expect(builder.heldModifier == nil)
    }
  }
#endif
