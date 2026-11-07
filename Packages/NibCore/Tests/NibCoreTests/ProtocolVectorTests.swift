import Foundation
import NibCore
import Testing

private struct SampleFields: Codable {
  let kind: String
  let sequence: UInt32
  let timestamp: UInt64
  let x: Float
  let y: Float
  let pressure: Float
  let altitude: Float
  let azimuth: Float
  let hoverDistance: UInt16
  let buttons: [String]
  let flags: [String]

  var sample: PenSample {
    let kind = PenSample.Kind.allCases.first { String(describing: $0) == self.kind }!
    var buttons: PenSample.Buttons = []
    if self.buttons.contains("eraser") { buttons.insert(.eraser) }
    if self.buttons.contains("barrel") { buttons.insert(.barrel) }
    var flags: PenSample.Flags = []
    if self.flags.contains("predicted") { flags.insert(.predicted) }
    if self.flags.contains("coalesced") { flags.insert(.coalesced) }
    return PenSample(
      kind: kind, sequence: sequence, timestamp: timestamp, x: x, y: y, pressure: pressure,
      altitude: altitude, azimuth: azimuth, hoverDistance: hoverDistance, buttons: buttons, flags: flags)
  }
}

private struct KeyVector: Codable, Equatable {
  let code: String
  let name: String
  let macKeyCode: UInt16
}

private enum ProtocolVectors {
  static var root: URL {
    // This test lives four directories below the repository root.
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  static func load(_ name: String) throws -> [[String: Any]] {
    let url = root.appendingPathComponent("protocol/vectors/\(name)")
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }

  static func bytes(_ value: Any) throws -> [UInt8] {
    let hex = try #require(value as? String)
    #expect(hex.count.isMultiple(of: 2))
    return stride(from: 0, to: hex.count, by: 2).map { offset in
      UInt8(hex.dropFirst(offset).prefix(2), radix: 16)!
    }
  }
}

@Test func controlVectorsRoundTripAndCoverEveryCase() throws {
  let vectors = try ProtocolVectors.load("control.json")
  let expectedNames: Set<String> = [
    "hello", "helloAck", "geometry", "ping", "probe", "probeReply", "frontApp",
    "gesture-scroll", "gesture-zoom", "gesture-rotate", "gesture-undo", "gesture-redo",
    "gesture-key", "gesture-key-modifier-only",
  ]
  #expect(Set(vectors.compactMap { $0["name"] as? String }) == expectedNames)
  #expect(vectors.count == expectedNames.count)

  let decoder = JSONDecoder()
  for vector in vectors {
    let json = try #require(vector["json"])
    let jsonData = try JSONSerialization.data(withJSONObject: json)
    let message = try decoder.decode(ControlMessage.self, from: jsonData)
    let framed = try ProtocolVectors.bytes(vector["framedHex"] as Any)
    var framer = ControlFramer()
    #expect(try framer.append(framed) == [message])
    #expect(ControlFramer.encode(message) == framed)
  }
}

@Test func sampleVectorsRoundTrip() throws {
  let vectors = try ProtocolVectors.load("samples.json")
  #expect(vectors.count == 9)
  for vector in vectors {
    let fieldsData = try JSONSerialization.data(withJSONObject: try #require(vector["fields"]))
    let fields = try JSONDecoder().decode(SampleFields.self, from: fieldsData)
    let vectorBytes = try ProtocolVectors.bytes(vector["hex"] as Any)
    #expect(try PenSample(decoding: vectorBytes) == fields.sample)
    #expect(fields.sample.encode() == vectorBytes)
  }
}

@Test func invalidVectorsHaveDocumentedOutcomes() throws {
  let vectors = try ProtocolVectors.load("invalid.json")
  #expect(vectors.map { $0["transport"] as? String }.allSatisfy { ["tcp", "udp", "usb"].contains($0 ?? "") })
  for vector in vectors {
    let name = try #require(vector["name"] as? String)
    let bytes = try ProtocolVectors.bytes(vector["hex"] as Any)
    switch name {
    case "unknown-control-type":
      var framer = ControlFramer()
      #expect(try framer.append(bytes).isEmpty)
    case "oversized-frame":
      var framer = ControlFramer()
      #expect(throws: ControlFramer.Error.oversized(65_537)) { try framer.append(bytes) }
    case "bad-magic":
      #expect(throws: PenSample.DecodeError.badMagic(0)) { try PenSample(decoding: bytes) }
    case "bad-version":
      #expect(throws: PenSample.DecodeError.unsupportedVersion(9)) { try PenSample(decoding: bytes) }
    case "wrong-length":
      #expect(throws: PenSample.DecodeError.wrongLength(39)) { try PenSample(decoding: bytes) }
    case "nan-pressure":
      #expect(throws: PenSample.DecodeError.invalidValue(field: "pressure")) {
        try PenSample(decoding: bytes)
      }
    case "out-of-range-x":
      #expect(throws: PenSample.DecodeError.invalidValue(field: "x")) { try PenSample(decoding: bytes) }
    default:
      Issue.record("Unknown invalid vector: \(name)")
    }
  }
}

@Test func keyVectorsMatchPickerTable() throws {
  let data = try Data(contentsOf: ProtocolVectors.root.appendingPathComponent("protocol/vectors/keys.json"))
  let vectors = try JSONDecoder().decode([KeyVector].self, from: data)
  let expected = KeyNames.pickerKeys.map {
    KeyVector(code: $0.code, name: $0.name, macKeyCode: $0.macKeyCode)
  }
  #expect(vectors == expected)
}
