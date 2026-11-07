import Foundation
import NibCore
import Testing

private final class MemoryTransport: LinkByteTransport, @unchecked Sendable {
  var bytes: Data?
  var closed = false
  func send(bytes: Data) { self.bytes = bytes }
  func close() { closed = true }
}

private final class Captured<T>: @unchecked Sendable {
  var value: T?
}

private func sessionData(_ hex: String) -> Data {
  Data(
    stride(from: 0, to: hex.count, by: 2).map {
      UInt8(hex.dropFirst($0).prefix(2), radix: 16)!
    })
}

@Test func authenticatedControlAndSampleRoundTrip() throws {
  let pairKey = sessionData("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
  let ipadNonce = sessionData("101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f")
  let hostNonce = sessionData("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f")
  var sender = try SessionCipher(
    pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .device)
  var receiver = try SessionCipher(
    pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .host)
  let plaintext = Data(#"{"type":"ping"}"#.utf8)
  let control = try sender.sealControl(plaintext)
  #expect(try receiver.openControl(control) == plaintext)
  let sample = Data(repeating: 0x5a, count: 40)
  let packet = try sender.sealSample(sample, sequence: 7)
  let opened = try receiver.openSample(packet)
  #expect(opened.sequence == 7)
  #expect(opened.plaintext == sample)
}

@Test func authenticatedFramesRejectTamperAndReplayOrGap() throws {
  let key = Data(repeating: 0x42, count: 32)
  let deviceNonce = Data(repeating: 0x10, count: 32)
  let hostNonce = Data(repeating: 0x20, count: 32)
  var sender = try SessionCipher(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce, role: .device)
  var receiver = try SessionCipher(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce, role: .host)
  var frame = try sender.sealControl(Data("first".utf8))
  #expect(try receiver.openControl(frame) == Data("first".utf8))
  #expect(throws: SessionCryptoError.counterMismatch(expected: 1, actual: 0)) {
    try receiver.openControl(frame)
  }
  frame[8] ^= 1
  #expect(throws: SessionCryptoError.counterMismatch(expected: 1, actual: 0)) {
    try receiver.openControl(frame)
  }
  let second = try sender.sealControl(Data("second".utf8))
  var tampered = second
  tampered[tampered.count - 1] ^= 1
  #expect(throws: SessionCryptoError.authenticationFailed) {
    try receiver.openControl(tampered)
  }
  let gapSender = try SessionSealer(
    key: try SessionKeyMaterial(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce).ipadToHost,
    epoch: try SessionKeyMaterial(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce).epoch,
    direction: .ipadToHost)
  let gap = try gapSender.sealControl(Data("gap".utf8), counter: 2)
  var gapReceiver = try SessionSealer(
    key: try SessionKeyMaterial(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce).ipadToHost,
    epoch: try SessionKeyMaterial(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce).epoch,
    direction: .ipadToHost)
  #expect(throws: SessionCryptoError.counterMismatch(expected: 0, actual: 2)) {
    try gapReceiver.openControl(gap)
  }
}

@Test func sampleEpochChangesWhenSessionRekeysBeforeSequenceWrap() throws {
  let pairKey = Data(repeating: 0x42, count: 32)
  let ipadNonce = Data(repeating: 0x10, count: 32)
  let hostNonce = Data(repeating: 0x20, count: 32)
  let nextHostNonce = Data(repeating: 0x21, count: 32)
  let first = try SessionKeyMaterial(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce)
  let second = try SessionKeyMaterial(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: nextHostNonce)
  #expect(first.epoch != second.epoch)
  let sealer = try SessionSealer(key: first.ipadToHost, epoch: first.epoch, direction: .ipadToHost)
  #expect(throws: SessionCryptoError.sequenceWrap) {
    try sealer.sealSample(Data(repeating: 0, count: 40), sequence: .max)
  }
}

@Test func sampleSealOpenBenchmarkStaysUnderBudget() throws {
  let key = Data(repeating: 0x42, count: 32)
  let nonce = Data(repeating: 0x10, count: 32)
  let hostNonce = Data(repeating: 0x20, count: 32)
  let material = try SessionKeyMaterial(pairKey: key, ipadNonce: nonce, hostNonce: hostNonce)
  let sender = try SessionSealer(key: material.ipadToHost, epoch: material.epoch, direction: .ipadToHost)
  let receiver = try SessionSealer(key: material.ipadToHost, epoch: material.epoch, direction: .ipadToHost)
  let sample = Data(repeating: 0x5a, count: 40)
  let start = DispatchTime.now().uptimeNanoseconds
  for sequence in UInt32(0)..<10_000 {
    let packet = try sender.sealSample(sample, sequence: sequence)
    _ = try receiver.openSample(packet)
  }
  let elapsed = DispatchTime.now().uptimeNanoseconds - start
  let micros = Double(elapsed) / 1_000 / 10_000
  print(String(format: "session sample seal/open benchmark: %.2f µs per operation (10k)", micros))
  #expect(micros < 20)
}

@Test func encryptedDispatchersUseProductionFramingPath() throws {
  let key = Data(repeating: 0x42, count: 32)
  let ipadNonce = Data(repeating: 0x10, count: 32)
  let hostNonce = Data(repeating: 0x20, count: 32)
  let deviceTransport = MemoryTransport()
  let hostTransport = MemoryTransport()
  let receivedControl = Captured<ControlMessage>()
  let receivedSample = Captured<PenSample>()
  let device = ControlLinkDispatcher(transport: deviceTransport) { _ in }
  let host = ControlLinkDispatcher(transport: hostTransport) { receivedControl.value = $0 }
  device.configureSession(
    try SessionCipher(
      pairKey: key, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .device))
  host.configureSession(
    try SessionCipher(
      pairKey: key, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .host))
  device.send(.ping)
  try host.receive(deviceTransport.bytes!)
  #expect(receivedControl.value == .ping)

  let sampleDeviceTransport = MemoryTransport()
  let sampleHostTransport = MemoryTransport()
  let sampleDevice = StreamLinkDispatcher(
    transport: sampleDeviceTransport, onControl: { _ in }, onSample: { _ in })
  let sampleHost = StreamLinkDispatcher(
    transport: sampleHostTransport, onControl: { _ in }, onSample: { receivedSample.value = $0 })
  sampleDevice.configureSession(
    try SessionCipher(
      pairKey: key, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .device))
  sampleHost.configureSession(
    try SessionCipher(
      pairKey: key, ipadNonce: ipadNonce, hostNonce: hostNonce, role: .host))
  let sample = PenSample(
    kind: .move, sequence: 8, timestamp: 9, x: 0.1, y: 0.2, pressure: 0.5,
    altitude: 1, azimuth: 2)
  sampleDevice.send(sample)
  try sampleHost.receive(sampleDeviceTransport.bytes!)
  #expect(receivedSample.value == sample)
}
