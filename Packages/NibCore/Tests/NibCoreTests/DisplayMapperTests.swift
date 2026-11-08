import CoreGraphics
import Foundation
import Testing

@testable import NibCore

private func mappedSample(x: Float, y: Float, pressure: Float = 0) -> PenSample {
  PenSample(
    kind: .move, sequence: 0, timestamp: 0, x: x, y: y, pressure: pressure, altitude: 1,
    azimuth: 0)
}

@Test func mappingSettingsRoundTripAndMinimumArea() throws {
  let settings = MappingSettings(
    target: .display(uuid: "display-a"),
    area: .init(x: 0.2, y: 0.3, width: 0.01, height: 2), proportions: .stretch)
  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(MappingSettings.self, from: data)
  #expect(
    decoded
      == MappingSettings(
        target: .display(uuid: "display-a"),
        area: .init(x: 0.2, y: 0.3, width: 0.1, height: 1), proportions: .stretch))
}

@Test func mappingSettingsDecodeClampsCorruptAndDefaultsMissingFields() throws {
  let corrupt = #"{"target":{"kind":"display","uuid":"main"},"area":{"x":9,"y":-2,"width":0,"height":9}}"#
    .data(using: .utf8)!
  let decoded = try JSONDecoder().decode(MappingSettings.self, from: corrupt)
  #expect(decoded.area == .init(x: 0.9, y: 0, width: 0.1, height: 1))
  let missing = try JSONDecoder().decode(MappingSettings.self, from: Data(#"{}"#.utf8))
  #expect(missing == MappingSettings(target: .followMain))
  let legacy = try JSONDecoder().decode(
    MappingSettings.self,
    from: Data(#"{"target":{"display":{"uuid":"legacy"}}}"#.utf8))
  #expect(legacy.target == .display(uuid: "legacy"))
}

@Test func missingDisplayFallsBackToMainAndReturnsWhenPresent() {
  let settings = MappingSettings(target: .display(uuid: "secondary"))
  let main = MappingSettings.Display(uuid: "main", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
  let secondary = MappingSettings.Display(
    uuid: "secondary", bounds: CGRect(x: -100, y: 20, width: 80, height: 60))
  #expect(settings.resolve(displays: [main], mainUUID: "main")?.usedFallback == true)
  #expect(settings.resolve(displays: [main], mainUUID: "main")?.rect == main.bounds)
  #expect(settings.resolve(displays: [main, secondary], mainUUID: "main")?.usedFallback == false)
  #expect(settings.resolve(displays: [main, secondary], mainUUID: "main")?.rect == secondary.bounds)
}

@Test func allDisplaysUnionSupportsNegativeOriginAndSubRect() {
  let settings = MappingSettings(
    area: .init(x: 0.25, y: 0, width: 0.5, height: 1), proportions: .stretch)
  let displays = [
    MappingSettings.Display(uuid: "main", bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
    MappingSettings.Display(uuid: "left", bounds: CGRect(x: -50, y: -20, width: 50, height: 120)),
  ]
  #expect(
    settings.resolve(displays: displays, mainUUID: "main")?.rect
      == CGRect(x: -12.5, y: -20, width: 75, height: 120))
}

@Test func previewAreaResolvesBackToTheSameSelectedScreenRect() {
  let displays = [
    MappingSettings.Display(uuid: "main", bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
    MappingSettings.Display(uuid: "upper", bounds: CGRect(x: 120, y: -40, width: 80, height: 60)),
  ]
  let settings = MappingSettings(
    target: .display(uuid: "upper"), area: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
  let base = settings.resolveBaseRect(displays: displays, mainUUID: "main")!.rect
  let previewBase = CGRect(x: 240, y: 20, width: 160, height: 120)
  let previewBox = MappingSettings.previewRect(for: settings.area, in: previewBase)
  let roundTrip = MappingSettings.area(from: previewBox, in: previewBase)
  #expect(
    settings.resolve(displays: displays, mainUUID: "main")!.rect
      == MappingSettings(target: .display(uuid: "upper"), area: roundTrip).resolve(
        displays: displays, mainUUID: "main")!.rect)
  #expect(base == CGRect(x: 120, y: -40, width: 80, height: 60))
}

@Test func movingAndResizingPreviewClampsBothEdges() {
  let base = CGRect(x: 0, y: 0, width: 200, height: 100)
  let moved = MappingSettings.area(
    from: CGRect(x: 190, y: 95, width: 100, height: 20), in: base)
  #expect(moved.x == 0.5)
  #expect(moved.y == 0.8)
  #expect(moved.width == 0.5)
  #expect(moved.height == 0.2)
}

@Test func stretchAndKeepProportionsDifferOnFourByThreeSurface() {
  let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
  let sample = mappedSample(x: 0.5, y: 0)
  let stretch = DisplayMapper(
    surfaceSize: CGSize(width: 4, height: 3), displayRect: rect, proportions: .stretch)
  let keep = DisplayMapper(surfaceSize: CGSize(width: 4, height: 3), displayRect: rect, proportions: .keep)
  #expect(stretch.map(sample).y == 0)
  #expect(keep.map(sample).y == 0)
  #expect(abs(stretch.map(sample).x - 800) < 0.01)
  #expect(abs(keep.map(sample).x - 800) < 0.01)
  #expect(abs(keep.map(mappedSample(x: 0.5, y: 0.1)).y - 0) < 0.01)
  #expect(abs(stretch.map(mappedSample(x: 0.5, y: 0.1)).y - 90) < 0.01)
}

@Test func widerDisplayMapsActiveAreaCorners() {
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 1_000, height: 1_000),
    displayRect: CGRect(x: 0, y: 0, width: 2_000, height: 1_000))
  #expect(mapper.map(mappedSample(x: 0, y: 0.25)).x == 0)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 0.75)).x - 1_999.999999) < 0.01)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 0.75)).y - 999.999999) < 0.01)
}

@Test func tallerDisplayMapsActiveAreaCorners() {
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 1_000, height: 1_000),
    displayRect: CGRect(x: 10, y: 20, width: 1_000, height: 2_000))
  #expect(mapper.map(mappedSample(x: 0.25, y: 0)) == CGPoint(x: 10, y: 20))
  #expect(abs(mapper.map(mappedSample(x: 0.75, y: 1)).x - 1_009.999999) < 0.01)
  #expect(abs(mapper.map(mappedSample(x: 0.75, y: 1)).y - 2_019.999999) < 0.01)
}

@Test func deadBandClampsToDisplayEdgeAndSupportsNegativeOrigin() {
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 2_000, height: 1_000),
    displayRect: CGRect(x: -1_440, y: 0, width: 1_440, height: 900))
  #expect(abs(mapper.map(mappedSample(x: 0, y: 0.5)).x + 1_440) < 0.01)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 0.5)).x + 0.000001) < 0.01)
}

@Test func zeroSurfaceUsesFullNormalizedSurface() {
  let mapper = DisplayMapper(
    surfaceSize: .zero, displayRect: CGRect(x: 4, y: -3, width: 100, height: 50))
  let point = mapper.map(mappedSample(x: 0.5, y: 0.25))
  #expect(abs(point.x - 54) < 0.01)
  #expect(abs(point.y - 9.5) < 0.01)
}

@Test func stretchMapsSubRectAndNegativeUnionEdges() {
  let displays = [
    MappingSettings.Display(uuid: "main", bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
    MappingSettings.Display(uuid: "left", bounds: CGRect(x: -100, y: 0, width: 100, height: 100)),
  ]
  let settings = MappingSettings(
    target: .allDisplays, area: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5), proportions: .stretch)
  let rect = settings.resolve(displays: displays, mainUUID: "main")!.rect
  let mapper = DisplayMapper(
    surfaceSize: CGSize(width: 4, height: 3), displayRect: rect, proportions: .stretch)
  #expect(mapper.map(mappedSample(x: 0, y: 0)) == rect.origin)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 1)).x - rect.maxX.nextDown) < 0.001)
  #expect(abs(mapper.map(mappedSample(x: 1, y: 1)).y - rect.maxY.nextDown) < 0.001)
}
