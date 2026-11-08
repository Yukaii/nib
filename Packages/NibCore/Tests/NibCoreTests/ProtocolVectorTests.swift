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
    "gesture-key", "gesture-key-modifier-only", "gesture-key-multi-modifier",
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

@Test func pairingVectorMatchesCryptoReference() throws {
  let url = ProtocolVectors.root.appendingPathComponent("protocol/vectors/pairing.json")
  let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  func data(_ key: String) throws -> Data { Data(try ProtocolVectors.bytes(try #require(object[key]))) }
  func string(_ key: String) throws -> String { try #require(object[key] as? String) }
  let deviceID = try string("deviceID")
  let hostID = try string("hostID")
  let device = try PairingKeyPair(privateKey: data("devicePrivateKey"))
  let host = try PairingKeyPair(privateKey: data("hostPrivateKey"))
  let expectedDevicePublic = try data("devicePublicKey")
  let expectedHostPublic = try data("hostPublicKey")
  #expect(device.publicKey == expectedDevicePublic)
  #expect(host.publicKey == expectedHostPublic)
  let deviceNonce = try data("deviceNonce")
  let hostNonce = try data("hostNonce")
  let helloDeviceNonce = try data("helloDeviceNonce")
  let helloHostNonce = try data("helloHostNonce")
  #expect(helloDeviceNonce != deviceNonce)
  #expect(helloHostNonce != hostNonce)
  let transcript = try PairingTranscript(
    deviceID: deviceID, hostID: hostID, devicePublicKey: device.publicKey,
    hostPublicKey: host.publicKey,
    deviceNonce: deviceNonce, hostNonce: hostNonce)
  let expectedHash = try data("transcriptHash")
  #expect(transcript.hash == expectedHash)
  let expectedCode = try string("code")
  #expect(PairingCrypto.numericCode(for: transcript) == expectedCode)
  let expectedPairKey = try data("pairKey")
  #expect(
    try PairingCrypto.pairKey(
      privateKey: device.privateKey, peerPublicKey: host.publicKey, transcript: transcript) == expectedPairKey
  )
  let pairKey = expectedPairKey
  let commitment = PairingCrypto.commitment(
    deviceID: deviceID, publicKey: device.publicKey, nonce: deviceNonce)
  let expectedCommitment = try data("commitment")
  #expect(commitment == expectedCommitment)
  #expect(
    PairingCrypto.verifyCommitment(
      commitment, deviceID: deviceID, publicKey: device.publicKey, nonce: deviceNonce))
  let deviceProof = PairingCrypto.helloProof(
    pairKey: pairKey, identifier: deviceID, nonce: helloDeviceNonce)
  let hostProof = PairingCrypto.hostProof(
    pairKey: pairKey, hostID: hostID, deviceNonce: helloDeviceNonce, hostNonce: helloHostNonce)
  let expectedDeviceProof = try data("deviceProof")
  let expectedHostProof = try data("hostProof")
  #expect(deviceProof == expectedDeviceProof)
  #expect(hostProof == expectedHostProof)
  // Negative vectors: wrong reveal, tampered transcript, proof under the wrong key.
  let wrongReveal = try data("wrongRevealNonce")
  #expect(
    !PairingCrypto.verifyCommitment(
      commitment, deviceID: deviceID, publicKey: device.publicKey, nonce: wrongReveal))
  #expect((object["wrongRevealValid"] as? Bool) == false)
  let tamperedCode = try string("tamperedCode")
  #expect(tamperedCode != expectedCode)
  #expect((object["tamperedDiffers"] as? Bool) == true)
  #expect(
    !PairingCrypto.verifyHelloProof(
      deviceProof, pairKey: Data(repeating: 0, count: 32), identifier: deviceID,
      nonce: helloDeviceNonce))
  #expect((object["wrongKeyValid"] as? Bool) == false)
  #expect(PairingCrypto.areLabelsPrefixFree())
}

@Test func sessionVectorMatchesCryptoReference() throws {
  let url = ProtocolVectors.root.appendingPathComponent("protocol/vectors/session.json")
  let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  func data(_ key: String) throws -> Data { Data(try ProtocolVectors.bytes(try #require(object[key]))) }
  let pairKey = try data("pairKey")
  let ipadNonce = try data("ipadNonce")
  let hostNonce = try data("hostNonce")
  let material = try SessionKeyMaterial(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce)
  let ipadToHostControlKey = try data("ipadToHostControlKey")
  let hostToIpadControlKey = try data("hostToIpadControlKey")
  let ipadToHostSampleKey = try data("ipadToHostSampleKey")
  let hostToIpadSampleKey = try data("hostToIpadSampleKey")
  let epoch = try data("epoch")
  let controlPlaintext = try data("controlPlaintext")
  let controlBody = try data("controlBody")
  let controlFrame = try data("controlFrame")
  let samplePlaintext = try data("samplePlaintext")
  let sampleDatagram = try data("sampleDatagram")
  #expect(material.ipadToHostControl == ipadToHostControlKey)
  #expect(material.hostToIpadControl == hostToIpadControlKey)
  #expect(material.ipadToHostSample == ipadToHostSampleKey)
  #expect(material.hostToIpadSample == hostToIpadSampleKey)
  #expect(material.epoch == epoch)
  var device = try SessionCipher(
    pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .device)
  var host = try SessionCipher(
    pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .host)
  let control = try device.sealControl(controlPlaintext)
  #expect(control == controlBody)
  var controlLength = UInt32(control.count).littleEndian
  let framedControl = Data(withUnsafeBytes(of: &controlLength) { Data($0) }) + control
  #expect(framedControl == controlFrame)
  #expect(try host.openControl(control) == controlPlaintext)
  let sample = try device.sealSample(samplePlaintext, sequence: 7)
  #expect(sample == sampleDatagram)
  let opened = try host.openSample(sample)
  #expect(opened.sequence == 7)
  #expect(opened.plaintext == samplePlaintext)
  let hostControl = try data("hostControlPlaintext")
  let hostControlBody = try data("hostControlBody")
  let hostControlFrame = try data("hostControlFrame")
  let sealedHostControl = try host.sealControl(hostControl)
  #expect(sealedHostControl == hostControlBody)
  var hostLength = UInt32(sealedHostControl.count).littleEndian
  #expect(Data(withUnsafeBytes(of: &hostLength) { Data($0) }) + sealedHostControl == hostControlFrame)
  #expect(try device.openControl(sealedHostControl) == hostControl)
  let hostSample = try data("hostSampleDatagram")
  #expect(try host.sealSample(samplePlaintext, sequence: 9) == hostSample)
  let openedHostSample = try device.openSample(hostSample)
  #expect(openedHostSample.sequence == 9)
  #expect(openedHostSample.plaintext == samplePlaintext)
}
