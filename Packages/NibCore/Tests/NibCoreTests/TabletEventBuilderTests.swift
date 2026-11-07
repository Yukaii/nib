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
    }

    let enter = try! #require(NSEvent(cgEvent: down[0]))
    let leave = try! #require(NSEvent(cgEvent: exit[0]))
    #expect(enter.type == .tabletProximity)
    #expect(enter.isEnteringProximity)
    #expect(leave.type == .tabletProximity)
    #expect(!leave.isEnteringProximity)
    #expect(down[0].getIntegerValueField(.tabletProximityEventDeviceID) == 1234)
    #expect(exit[0].getIntegerValueField(.tabletProximityEventDeviceID) == 1234)
  }
#endif
