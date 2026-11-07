#if os(macOS)
  import AppKit
  import CoreGraphics
  import Testing
  @testable import NibCore

  private func injectionSample(_ kind: PenSample.Kind, x: Float, y: Float, pressure: Float) -> PenSample {
    PenSample(
      kind: kind, sequence: 0, timestamp: 0, x: x, y: y, pressure: pressure, altitude: 1,
      azimuth: 0)
  }

  @Test func pressureAndMappedPointsReachPostedEvents() throws {
    var posted: [CGEvent] = []
    var controller = PenInjectionController(
      surfaceSize: CGSize(width: 1_000, height: 1_000),
      displayRect: CGRect(x: 0, y: 0, width: 2_000, height: 1_000),
      post: { posted.append(contentsOf: $0) }, isTrusted: { true })

    _ = controller.handle(injectionSample(.down, x: 0.25, y: 0.25, pressure: 0.2))
    _ = controller.handle(injectionSample(.move, x: 0.5, y: 0.5, pressure: 0.7))
    _ = controller.handle(injectionSample(.up, x: 0.75, y: 0.75, pressure: 0.9))

    let points = posted.filter { $0.type != .tabletProximity }
    #expect(points.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    #expect(points.map { $0.location }.count == 3)
    #expect(abs(points[0].location.x - 500) < 0.01)
    #expect(abs(points[1].location.x - 1_000) < 0.01)
    #expect(abs(points[2].location.x - 1_500) < 0.01)
    #expect(abs(points[0].getDoubleValueField(.tabletEventPointPressure) - 0.2) < 0.001)
    #expect(abs(points[1].getDoubleValueField(.tabletEventPointPressure) - 0.7) < 0.001)
    #expect(abs(points[2].getDoubleValueField(.tabletEventPointPressure) - 0.9) < 0.001)
  }

  @Test func sessionEndReleasesButtonAndExitsProximity() {
    var posted: [CGEvent] = []
    var controller = PenInjectionController(
      displayRect: CGRect(x: 0, y: 0, width: 100, height: 100), post: { posted.append(contentsOf: $0) },
      isTrusted: { true })
    _ = controller.handle(injectionSample(.down, x: 0.5, y: 0.5, pressure: 0.4))
    controller.sessionEnded()
    #expect(posted.suffix(2).map(\.type) == [.leftMouseUp, .tabletProximity])
    #expect((posted.last?.getIntegerValueField(.tabletProximityEventEnterProximity) ?? 1) == 0)
  }

  @Test func penDownDoesNotReleaseHeldSpaceShortcut() {
    var posted: [CGEvent] = []
    var controller = PenInjectionController(
      displayRect: CGRect(x: 0, y: 0, width: 100, height: 100), post: { posted.append(contentsOf: $0) },
      isTrusted: { true })
    _ = controller.handle(.key(.init(keyCode: 49), action: .down))
    posted.removeAll()

    _ = controller.handle(injectionSample(.down, x: 0.5, y: 0.5, pressure: 0.4))

    #expect(
      !posted.contains {
        $0.type == .keyUp && $0.getIntegerValueField(.keyboardEventKeycode) == 49
      })
  }

  @Test func untrustedControllerPostsNothing() {
    var postCount = 0
    var controller = PenInjectionController(
      displayRect: CGRect(x: 0, y: 0, width: 100, height: 100), post: { postCount += $0.count },
      isTrusted: { false })
    let accepted = controller.handle(injectionSample(.down, x: 0.5, y: 0.5, pressure: 1))
    #expect(!accepted)
    controller.sessionEnded()
    #expect(postCount == 0)
    #expect(!controller.accessibilityTrusted)
  }
#endif
