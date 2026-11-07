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

private final class DataCapture: @unchecked Sendable {
  let lock = NSLock()
  var values: [Data] = []
  func append(_ value: Data) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
}
private final class MessageCapture: @unchecked Sendable {
  let lock = NSLock()
  var values: [ControlMessage] = []
  func append(_ value: ControlMessage) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
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
  let sealStart = DispatchTime.now().uptimeNanoseconds
  var packets: [Data] = []
  packets.reserveCapacity(10_000)
  for sequence in UInt32(0)..<10_000 {
    packets.append(try sender.sealSample(sample, sequence: sequence))
  }
  let sealMicros = Double(DispatchTime.now().uptimeNanoseconds - sealStart) / 1_000 / 10_000
  let openStart = DispatchTime.now().uptimeNanoseconds
  for packet in packets { _ = try receiver.openSample(packet) }
  let openMicros = Double(DispatchTime.now().uptimeNanoseconds - openStart) / 1_000 / 10_000
  print(String(format: "session sample seal benchmark: %.2f µs per seal (10k)", sealMicros))
  print(String(format: "session sample open benchmark: %.2f µs per open (10k)", openMicros))
}

@Test func concurrentControlCountersRemainUnique() throws {
  let key = Data(repeating: 0x42, count: 32)
  let nonce = Data(repeating: 0x10, count: 32)
  let host = Data(repeating: 0x20, count: 32)
  let sender = try SessionCipher(pairKey: key, ipadNonce: nonce, hostNonce: host, role: .device)
  let frames = DataCapture()
  DispatchQueue.concurrentPerform(iterations: 10_000) { i in
    if let frame = try? sender.sealControl(Data("\(i)".utf8)) { frames.append(frame) }
  }
  #expect(frames.values.count == 10_000)
  let counters = Set(frames.values.map { $0.prefix(8) })
  #expect(counters.count == 10_000)
  let receiver = try SessionCipher(pairKey: key, ipadNonce: nonce, hostNonce: host, role: .host)
  func counter(_ frame: Data) -> UInt64 {
    frame.prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (UInt64($1.offset) * 8) }
  }
  for frame in frames.values.sorted(by: { counter($0) < counter($1) }) { _ = try receiver.openControl(frame) }
}

@Test func sampleSealRejectsPredictedAndConflictingReseal() throws {
  let material = try SessionKeyMaterial(
    pairKey: Data(repeating: 1, count: 32), ipadNonce: Data(repeating: 2, count: 32),
    hostNonce: Data(repeating: 3, count: 32))
  let sealer = try SessionSealer(
    key: material.ipadToHostSample, epoch: material.epoch, direction: .ipadToHost)
  var sample = PenSample(
    kind: .move, sequence: UInt32.max - 2, timestamp: 1, x: 0, y: 0, pressure: 1, altitude: 1, azimuth: 1)
  _ = try sealer.sealSample(Data(sample.encode()), sequence: sample.sequence)
  _ = try sealer.sealSample(Data(sample.encode()), sequence: sample.sequence)
  sample.pressure = 0.5
  #expect(throws: SessionCryptoError.sequenceReplay) {
    try sealer.sealSample(Data(sample.encode()), sequence: sample.sequence)
  }
  sample.flags = [.predicted]
  #expect(throws: SessionCryptoError.invalidSampleFrame) {
    try sealer.sealSample(Data(sample.encode()), sequence: sample.sequence &+ 1)
  }
  #expect(throws: SessionCryptoError.sequenceWrap) {
    try sealer.sealSample(
      Data(
        PenSample(kind: .move, sequence: .max, timestamp: 1, x: 0, y: 0, pressure: 1, altitude: 1, azimuth: 1)
          .encode()), sequence: .max)
  }
}

@Test func dispatcherArmsAfterPlaintextAckBeforeBufferedSealedFrame() throws {
  let key = Data(repeating: 0x42, count: 32)
  let nonce = Data(repeating: 0x10, count: 32)
  let hostNonce = Data(repeating: 0x20, count: 32)
  let host = try SessionCipher(pairKey: key, ipadNonce: nonce, hostNonce: hostNonce, role: .host)
  let ack = Data(ControlFramer().encode(.helloAck(.init(accepted: true))))
  let sealed = try host.sealControl(
    Data(ControlFramer().encode(.frontApp(.init(appID: "com.test", name: "Test"))).dropFirst(4)))
  var length = UInt32(sealed.count).littleEndian
  let framed = Data(withUnsafeBytes(of: &length) { Data($0) }) + sealed
  for split in [ack.count, ack.count / 2] {
    let transport = MemoryTransport()
    let received = MessageCapture()
    let dispatcher = ControlLinkDispatcher(
      transport: transport,
      armSession: { _ in
        try? SessionCipher(pairKey: key, ipadNonce: nonce, hostNonce: hostNonce, role: .device)
      }, onMessage: { received.append($0) })
    let all = ack + framed
    try dispatcher.receive(all.prefix(split))
    try dispatcher.receive(all.dropFirst(split))
    #expect(received.values.contains(.helloAck(.init(accepted: true))))
    #expect(received.values.contains(.frontApp(.init(appID: "com.test", name: "Test"))))
  }
  let streamAck = Data(StreamFramer.encode(.control(.helloAck(.init(accepted: true)))))
  var streamLength = UInt32(sealed.count).littleEndian
  let streamSealed =
    Data([StreamFramer.controlType]) + Data(withUnsafeBytes(of: &streamLength) { Data($0) }) + sealed
  let streamTransport = MemoryTransport()
  let streamReceived = MessageCapture()
  let stream = StreamLinkDispatcher(
    transport: streamTransport,
    armSession: { _ in try? SessionCipher(pairKey: key, ipadNonce: nonce, hostNonce: hostNonce, role: .device)
    }, onControl: { streamReceived.append($0) }, onSample: { _ in })
  try stream.receive(streamAck + streamSealed)
  #expect(streamReceived.values.contains(.helloAck(.init(accepted: true))))
  #expect(streamReceived.values.contains(.frontApp(.init(appID: "com.test", name: "Test"))))
}

@Test func replayedHelloGetsFreshHostNonceAndIsolatedCipher() throws {
  let key = Data(repeating: 0x42, count: 32)
  let deviceNonce = Data(repeating: 0x10, count: 32)
  let store = InMemoryPairingKeyStore()
  store.save(key, for: "device")
  var host = HostLink(store: store, hostID: "host")
  let nonce = PairingCrypto.base64(deviceNonce)
  let proof = PairingCrypto.base64(
    PairingCrypto.helloProof(pairKey: key, identifier: "device", nonce: deviceNonce))
  let hello = ControlMessage.Hello(
    appVersion: "test", deviceID: "device", deviceName: "iPad", surfaceWidth: 1, surfaceHeight: 1,
    nonce: nonce, proof: proof)
  guard
    case .authenticated(let firstHello) = host.receiveHello(
      hello, connectionGeneration: 1, busy: false, now: 0)
  else {
    Issue.record("first hello not authenticated")
    return
  }
  let firstAck = host.acceptHello(
    firstHello, now: 0, udpPort: 1, displayWidth: 1, displayHeight: 1, host: nil)
  guard let firstParameters = host.sessionParameters else {
    Issue.record("first session missing")
    return
  }
  host.connectionLost(1)
  host.sessionConnected = false
  host.session.disconnect()
  guard
    case .authenticated(let secondHello) = host.receiveHello(
      hello, connectionGeneration: 2, busy: false, now: 1)
  else {
    Issue.record("replayed hello not accepted")
    return
  }
  let secondAck = host.acceptHello(
    secondHello, now: 1, udpPort: 1, displayWidth: 1, displayHeight: 1, host: nil)
  guard let secondParameters = host.sessionParameters else {
    Issue.record("second session missing")
    return
  }
  #expect(firstAck.nonce != secondAck.nonce)
  let firstDevice = try SessionCipher(
    pairKey: key, ipadNonce: deviceNonce, hostNonce: firstParameters.hostNonce, role: .device)
  let secondDevice = try SessionCipher(
    pairKey: key, ipadNonce: deviceNonce, hostNonce: secondParameters.hostNonce, role: .device)
  let firstFrame = try firstDevice.sealControl(Data("first".utf8))
  let secondFrame = try secondDevice.sealControl(Data("second".utf8))
  #expect(throws: SessionCryptoError.authenticationFailed) {
    try SessionCipher(
      pairKey: key, ipadNonce: deviceNonce, hostNonce: secondParameters.hostNonce, role: .host
    ).openControl(firstFrame)
  }
  #expect(throws: SessionCryptoError.authenticationFailed) {
    try SessionCipher(pairKey: key, ipadNonce: deviceNonce, hostNonce: firstParameters.hostNonce, role: .host)
      .openControl(secondFrame)
  }
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
