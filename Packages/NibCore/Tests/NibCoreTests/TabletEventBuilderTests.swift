#if os(macOS)
  import AppKit
  import CoreGraphics
  import Testing
  @testable import NibCore

  private func sample(_ kind: PenSample.Kind, pressure: Float, altitude: Float, azimuth: Float) -> PenSample {
    PenSample(
      kind: kind, sequence: 0, timestamp: 0, x: 0.5, y: 0.5, pressure: pressure, altitude: altitude,
      azimuth: azimuth)
  }

  @Test func builderProducesTabletPressureTiltAndProximity() {
    var builder = TabletEventBuilder(deviceID: 1234)
    let down = builder.events(
      for: sample(.down, pressure: 0.2, altitude: .pi / 4, azimuth: 0), at: CGPoint(x: 10, y: 20))
    let move = builder.events(
      for: sample(.move, pressure: 0.75, altitude: .pi / 4, azimuth: .pi / 2), at: CGPoint(x: 11, y: 21))
    let up = builder.events(
      for: sample(.up, pressure: 0, altitude: .pi / 2, azimuth: 0), at: CGPoint(x: 12, y: 22))
    let exit = builder.events(
      for: sample(.proximityExit, pressure: 0, altitude: 0, azimuth: 0), at: CGPoint(x: 12, y: 22))

    #expect(down.count == 2)
    #expect(move.count == 1)
    #expect(up.count == 1)
    #expect(exit.count == 1)

    let pointEvents = [down[1], move[0], up[0]]
    let expectedPressures = [0.2, 0.75, 0.0]
    let expectedTilts = [(sqrt(0.5), 0.0), (0.0, sqrt(0.5)), (0.0, 0.0)]
    for (index, cgEvent) in pointEvents.enumerated() {
      let event = try! #require(NSEvent(cgEvent: cgEvent))
      #expect(event.subtype == .tabletPoint)
      #expect(abs(Double(event.pressure) - expectedPressures[index]) < 0.01)
      #expect(abs(Double(event.tilt.x) - expectedTilts[index].0) < 0.01)
      #expect(abs(Double(event.tilt.y) - expectedTilts[index].1) < 0.01)
      #expect(abs(cgEvent.getDoubleValueField(.mouseEventPressure) - expectedPressures[index]) < 0.01)
      #expect(abs(cgEvent.getDoubleValueField(.tabletEventPointPressure) - expectedPressures[index]) < 0.01)
      #expect(cgEvent.getIntegerValueField(.tabletEventDeviceID) == 1234)
      #expect(cgEvent.getIntegerValueField(.tabletEventPointButtons) == (index == 2 ? 0 : 1))
      #expect(cgEvent.getIntegerValueField(.mouseEventClickState) == 1)
    }

    let enter = try! #require(NSEvent(cgEvent: down[0]))
    let leave = try! #require(NSEvent(cgEvent: exit[0]))
    #expect(enter.type == .tabletProximity)
    #expect(enter.isEnteringProximity)
    #expect(leave.type == .tabletProximity)
    #expect(!leave.isEnteringProximity)
    #expect(down[0].getIntegerValueField(.tabletProximityEventDeviceID) == 1234)
    #expect(exit[0].getIntegerValueField(.tabletProximityEventDeviceID) == 1234)
    #expect(down[0].getIntegerValueField(.tabletProximityEventPointerID) != 0)
    #expect(down[0].getIntegerValueField(.tabletProximityEventVendorID) != 0)
    let capabilities = enter.capabilityMask
    #expect(Int64(capabilities) == 0x05C7)
    #expect((capabilities & 0x0400) != 0)
    #expect((capabilities & 0x0080) != 0)
    #expect((capabilities & 0x0100) != 0)
  }

  @Test func builderMaintainsWellFormedButtonState() {
    var builder = TabletEventBuilder()
    let move = builder.events(for: sample(.move, pressure: 0.5, altitude: 1, azimuth: 0), at: .zero)
    #expect(move.map(\.type) == [.tabletProximity, .leftMouseDown, .leftMouseDragged])
    #expect(builder.isButtonDown)

    let duplicateDown = builder.events(for: sample(.down, pressure: 0.5, altitude: 1, azimuth: 0), at: .zero)
    #expect(duplicateDown.map(\.type) == [.leftMouseDragged])

    let hover = builder.events(for: sample(.hover, pressure: 0, altitude: 1, azimuth: 0), at: .zero)
    #expect(hover.map(\.type) == [.leftMouseUp, .mouseMoved])
    #expect(!builder.isButtonDown)
    #expect(hover[0].getIntegerValueField(.tabletEventPointButtons) == 0)
    #expect(hover[1].getIntegerValueField(.tabletEventPointButtons) == 0)
    #expect(hover[1].getIntegerValueField(.mouseEventClickState) == 0)
    #expect(builder.events(for: sample(.up, pressure: 0, altitude: 1, azimuth: 0), at: .zero).isEmpty)
    #expect(builder.events(for: sample(.cancel, pressure: 0, altitude: 1, azimuth: 0), at: .zero).isEmpty)

    _ = builder.events(for: sample(.down, pressure: 0.5, altitude: 1, azimuth: 0), at: .zero)
    let exit = builder.events(for: sample(.proximityExit, pressure: 0, altitude: 1, azimuth: 0), at: .zero)
    #expect(exit.map(\.type) == [.leftMouseUp, .tabletProximity])
    #expect(!builder.inProximity)
    #expect(!builder.isButtonDown)
  }

  @Test func pointerTypeChangeRestartsProximityAndDefersDuringStroke() {
    var builder = TabletEventBuilder()
    let penHover = builder.events(for: sample(.hover, pressure: 0, altitude: 1, azimuth: 0), at: .zero)
    #expect(penHover.count == 2)
    let eraserHover = builder.events(
      for: sampleWithButtons(.hover, buttons: .eraser), at: .zero)
    #expect(eraserHover.map(\.type) == [.tabletProximity, .tabletProximity, .mouseMoved])
    #expect(eraserHover[0].getIntegerValueField(.tabletProximityEventEnterProximity) == 0)
    #expect(eraserHover[1].getIntegerValueField(.tabletProximityEventEnterProximity) == 1)

    var strokeBuilder = TabletEventBuilder()
    _ = strokeBuilder.events(for: sample(.hover, pressure: 0, altitude: 1, azimuth: 0), at: .zero)
    _ = strokeBuilder.events(for: sample(.down, pressure: 0.5, altitude: 1, azimuth: 0), at: .zero)
    let deferred = strokeBuilder.events(
      for: sampleWithButtons(.down, buttons: .eraser), at: .zero)
    #expect(deferred.map(\.type) == [.leftMouseDragged])
    let up = strokeBuilder.events(for: sampleWithButtons(.up, buttons: .eraser), at: .zero)
    #expect(up.map(\.type) == [.leftMouseUp, .tabletProximity, .tabletProximity])
    #expect(up[1].getIntegerValueField(.tabletProximityEventEnterProximity) == 0)
    #expect(up[2].getIntegerValueField(.tabletProximityEventEnterProximity) == 1)
  }

  @Test func predictedSamplesProduceNoEvents() {
    var builder = TabletEventBuilder()
    let predicted = sample(.down, pressure: 1, altitude: 1, azimuth: 0)
    var flagged = predicted
    flagged.flags = [.predicted]
    #expect(builder.events(for: flagged, at: .zero).isEmpty)
    #expect(!builder.inProximity)
    #expect(!builder.isButtonDown)
  }

  @Test func fullHoverStrokeProximitySequenceIsStable() {
    var builder = TabletEventBuilder()
    let samples: [PenSample] = [
      sample(.hover, pressure: 0, altitude: 1, azimuth: 0),
      sample(.down, pressure: 0.2, altitude: 1, azimuth: 0),
      sample(.move, pressure: 0.7, altitude: 1, azimuth: 0),
      sample(.up, pressure: 0, altitude: 1, azimuth: 0),
      sample(.hover, pressure: 0, altitude: 1, azimuth: 0),
      sample(.proximityExit, pressure: 0, altitude: 1, azimuth: 0),
    ]
    let types = samples.flatMap { builder.events(for: $0, at: .zero).map(\.type) }
    #expect(
      types == [
        .tabletProximity, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved,
        .tabletProximity,
      ])
  }

  private func sampleWithButtons(_ kind: PenSample.Kind, buttons: PenSample.Buttons) -> PenSample {
    PenSample(
      kind: kind, sequence: 0, timestamp: 0, x: 0.5, y: 0.5, pressure: kind == .up ? 0 : 0.5,
      altitude: 1, azimuth: 0, buttons: buttons)
  }
#endif
