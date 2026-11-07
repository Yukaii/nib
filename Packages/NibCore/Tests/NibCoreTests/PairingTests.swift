import Foundation
import NibCore
import Testing

private func hex(_ value: String) -> Data {
  Data(
    stride(from: 0, to: value.count, by: 2).map {
      UInt8(value.dropFirst($0).prefix(2), radix: 16)!
    })
}

private func framerRoundTrip(_ message: ControlMessage) throws -> ControlMessage {
  var framer = ControlFramer()
  let decoded = try framer.append(ControlFramer.encode(message))
  return try #require(decoded.first)
}

struct PairingTests {
  private let devicePrivate = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
  private let hostPrivate = hex("2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40")
  private let deviceNonce = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
  private let hostNonce = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf")

  @Test func cryptoMatchesPairingVector() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let transcript = try PairingTranscript(
      devicePublicKey: device.publicKey, hostPublicKey: host.publicKey,
      deviceNonce: deviceNonce, hostNonce: hostNonce)
    #expect(PairingCrypto.numericCode(for: transcript) == "463962")
    #expect(transcript.hash == hex("1bccf65ba7af7bac25ca1d9158d23ccbcbd1ef02d6350b477d4ff7586f37b157"))
    let pairKey = try PairingCrypto.pairKey(
      privateKey: device.privateKey, peerPublicKey: host.publicKey, transcript: transcript)
    #expect(pairKey == hex("cacc6ce751d9df5cedeb877f88b5270868b5c66deb5edb22159b000b365e1fc7"))
    let commitment = PairingCrypto.commitment(publicKey: device.publicKey, nonce: deviceNonce)
    #expect(commitment == hex("64d7bc166fa7fa0d26fcc3cf951b1a0e302c63d3bc08e6841f3e75197565060d"))
    #expect(PairingCrypto.verifyCommitment(commitment, publicKey: device.publicKey, nonce: deviceNonce))
    #expect(
      !PairingCrypto.verifyCommitment(
        commitment, publicKey: device.publicKey, nonce: Data(repeating: 0, count: 32)))
    let deviceProof = PairingCrypto.helloProof(
      pairKey: pairKey, identifier: "device-001", nonce: deviceNonce)
    #expect(deviceProof == hex("c68a8a2b651ea2336fd1d356fe765aff59adab66495cac6272178cb87d6a5d28"))
    #expect(
      PairingCrypto.verifyHelloProof(
        deviceProof, pairKey: pairKey, identifier: "device-001", nonce: deviceNonce))
    #expect(
      !PairingCrypto.verifyHelloProof(
        deviceProof, pairKey: Data(repeating: 0, count: 32), identifier: "device-001",
        nonce: deviceNonce))
    let hostProof = PairingCrypto.hostProof(
      pairKey: pairKey, hostID: "host-001", deviceNonce: deviceNonce, hostNonce: hostNonce)
    #expect(hostProof == hex("d53fc8039db22b9e73170a54827bc4d567fc7a2b0d90c44535980bb0827b2fe5"))
    #expect(
      PairingCrypto.verifyHostProof(
        hostProof, pairKey: pairKey, hostID: "host-001", deviceNonce: deviceNonce,
        hostNonce: hostNonce))
    #expect(
      !PairingCrypto.verifyHostProof(
        hostProof, pairKey: pairKey, hostID: "host-001", deviceNonce: Data(repeating: 1, count: 32),
        hostNonce: hostNonce))
    #expect(
      PairingCrypto.numericCode(
        for: try PairingTranscript(
          devicePublicKey: device.publicKey, hostPublicKey: host.publicKey,
          deviceNonce: Data(repeating: 0, count: 32), hostNonce: hostNonce)) != "463962")
  }

  @Test func pairingMessagesAndAuthenticatedHelloRoundTrip() throws {
    let messages: [ControlMessage] = [
      .pairRequest(
        .init(deviceID: "device", deviceName: "iPad", publicKey: "key", commitment: "commitment")),
      .pairResponse(.init(hostID: "host", hostName: "Mac", publicKey: "key", nonce: "nonce")),
      .pairReveal(.init(nonce: "nonce")),
      .pairResult(.init(accepted: false, reason: "Pair again")),
      .hello(
        .init(
          appVersion: "0.3.0", deviceID: "device", deviceName: "iPad", surfaceWidth: 1,
          surfaceHeight: 2, nonce: "nonce", proof: "proof")),
      .helloAck(.init(accepted: true, nonce: "nonce", proof: "proof")),
    ]
    for message in messages {
      #expect(try framerRoundTrip(message) == message)
    }
  }

  @Test func pairingStateMachineCommitRevealHappyPathThroughFramer() throws {
    let deviceStore = InMemoryPairingKeyStore()
    let hostStore = InMemoryPairingKeyStore()
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad", keyPair: try PairingKeyPair(privateKey: devicePrivate),
      store: deviceStore)
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    let requestEvent = try #require(try device.begin(nonce: deviceNonce))
    guard case .send(let requestMessage) = requestEvent else {
      Issue.record("device begin must send a pairRequest")
      return
    }
    // The request carries a commitment, never the nonce itself.
    guard case .pairRequest(let request) = try framerRoundTrip(requestMessage) else {
      Issue.record("expected pairRequest on the wire")
      return
    }
    #expect(request.commitment.count > 0)
    if let nonceData = Data(base64Encoded: request.commitment) {
      #expect(nonceData != deviceNonce)
    }
    let responseEvents = host.receive(try framerRoundTrip(requestMessage))
    // The host sends its nonce first and shows no code before a valid reveal.
    #expect(responseEvents.compactMap(code).isEmpty)
    #expect(host.phase == .waitingForReveal)
    let responseMessage = try #require(responseEvents.compactMap(message).first)
    let deviceEvents = device.receive(try framerRoundTrip(responseMessage))
    let deviceCode = try #require(deviceEvents.compactMap(code).first)
    let revealMessage = try #require(deviceEvents.compactMap(message).first)
    guard case .pairReveal = try framerRoundTrip(revealMessage) else {
      Issue.record("device must reveal its nonce after the response")
      return
    }
    let hostCodeEvents = host.receive(try framerRoundTrip(revealMessage))
    let hostCode = try #require(hostCodeEvents.compactMap(code).first)
    #expect(deviceCode == hostCode)
    #expect(deviceStore.key(for: "host-001") == nil)
    #expect(hostStore.key(for: "device-001") == nil)
    let deviceResult = try #require(device.confirm().compactMap(message).first)
    #expect(host.receive(try framerRoundTrip(deviceResult)).isEmpty)
    #expect(hostStore.key(for: "device-001") == nil)
    let hostResult = try #require(host.confirm().compactMap(message).first)
    #expect(host.phase == .paired)
    let devicePaired = device.receive(try framerRoundTrip(hostResult))
    #expect(devicePaired.contains(.paired(peerID: "host-001")))
    #expect(device.phase == .paired)
    #expect(deviceStore.key(for: "host-001") != nil)
    #expect(hostStore.key(for: "device-001") != nil)
  }

  @Test func wrongRevealFailsAndStoresNothing() throws {
    let deviceStore = InMemoryPairingKeyStore()
    let hostStore = InMemoryPairingKeyStore()
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: deviceStore)
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    let request = try #require(try device.begin(nonce: deviceNonce))
    let requestOnWire = try framerRoundTrip(try #require(message(from: request)))
    let responseEvents = host.receive(requestOnWire)
    #expect(responseEvents.compactMap(code).isEmpty)
    let response = try #require(responseEvents.compactMap(message).first)
    let deviceEvents = device.receive(try framerRoundTrip(response))
    #expect(deviceEvents.compactMap(code).first != nil)
    // Tamper with the reveal: the host must reject a nonce that does not
    // match the earlier commitment.
    let badReveal = ControlMessage.pairReveal(
      .init(nonce: PairingCrypto.base64(Data(repeating: 0, count: 32))))
    let result = host.receive(try framerRoundTrip(badReveal))
    #expect(result.count == 1)
    guard case .failed = result.first else {
      Issue.record("wrong reveal must fail pairing, got \(result)")
      return
    }
    #expect(host.phase == .failed)
    #expect(hostStore.key(for: "device-001") == nil)
    #expect(deviceStore.key(for: "host-001") == nil)
  }

  @Test func tamperedKeyOrNonceChangesCode() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let baseline = try PairingTranscript(
      devicePublicKey: device.publicKey, hostPublicKey: host.publicKey,
      deviceNonce: deviceNonce, hostNonce: hostNonce)
    let baselineCode = PairingCrypto.numericCode(for: baseline)
    var tamperedKey = host.publicKey
    tamperedKey[0] ^= 0x01
    let tamperedKeyCode = PairingCrypto.numericCode(
      for: try PairingTranscript(
        devicePublicKey: device.publicKey, hostPublicKey: tamperedKey,
        deviceNonce: deviceNonce, hostNonce: hostNonce))
    #expect(tamperedKeyCode != baselineCode)
    let tamperedNonceCode = PairingCrypto.numericCode(
      for: try PairingTranscript(
        devicePublicKey: device.publicKey, hostPublicKey: host.publicKey,
        deviceNonce: Data(repeating: 0, count: 32), hostNonce: hostNonce))
    #expect(tamperedNonceCode != baselineCode)
  }

  @Test func cancelAndTimeoutDoNotStoreKeys() throws {
    let store = InMemoryPairingKeyStore()
    var machine = PairingStateMachine(
      role: .device, id: "device", name: "iPad", keyPair: try PairingKeyPair(privateKey: devicePrivate),
      store: store)
    _ = try machine.begin(nonce: deviceNonce)
    #expect(machine.cancel() == .send(.pairResult(.init(accepted: false, reason: "Pairing cancelled."))))
    #expect(machine.phase == .cancelled)
    #expect(store.key(for: "host") == nil)
    var timedOut = PairingStateMachine(
      role: .device, id: "device", name: "iPad", keyPair: try PairingKeyPair(privateKey: devicePrivate),
      store: store)
    _ = try timedOut.begin(nonce: deviceNonce)
    #expect(timedOut.timeout() == .timedOut)
    #expect(timedOut.phase == .timedOut)
    #expect(store.key(for: "host") == nil)
    // A host that never receives a reveal times out with nothing stored.
    let hostStore = InMemoryPairingKeyStore()
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    var soloDevice = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    let soloRequest = try #require(try soloDevice.begin(nonce: deviceNonce))
    _ = host.receive(try framerRoundTrip(try #require(message(from: soloRequest))))
    #expect(host.phase == .waitingForReveal)
    #expect(host.timeout() == .timedOut)
    #expect(hostStore.key(for: "device-001") == nil)
  }

  @Test func hostCancelAndPeerCancelLeaveNoStoredKey() throws {
    let deviceStore = InMemoryPairingKeyStore()
    let hostStore = InMemoryPairingKeyStore()
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: deviceStore)
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    let request = try #require(try device.begin(nonce: deviceNonce))
    let responseEvents = host.receive(try framerRoundTrip(try #require(message(from: request))))
    let response = try #require(responseEvents.compactMap(message).first)
    let deviceEvents = device.receive(try framerRoundTrip(response))
    let reveal = try #require(deviceEvents.compactMap(message).first)
    #expect(host.receive(try framerRoundTrip(reveal)).compactMap(code).first != nil)
    // Host cancels locally: emits a rejection and stores nothing.
    let hostCancel = host.cancel()
    guard case .send(let cancelMessage) = hostCancel else {
      Issue.record("host cancel must send a pairResult")
      return
    }
    #expect(host.phase == .cancelled)
    #expect(hostStore.key(for: "device-001") == nil)
    // The peer observes the rejection and stores nothing either.
    #expect(device.receive(try framerRoundTrip(cancelMessage)) == [.cancelled])
    #expect(device.phase == .cancelled)
    #expect(deviceStore.key(for: "host-001") == nil)
  }

  @Test func receiverRejectsMissingOrBadProofAndAcceptsValidProof() throws {
    let key = hex("cacc6ce751d9df5cedeb877f88b5270868b5c66deb5edb22159b000b365e1fc7")
    let nonce = PairingCrypto.base64(deviceNonce)
    let proof = PairingCrypto.base64(
      PairingCrypto.helloProof(pairKey: key, identifier: "device-001", nonce: deviceNonce))
    let makeHello: (String?, String?) -> ControlMessage.Hello = { nonce, proof in
      .init(
        appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 1, surfaceHeight: 1,
        nonce: nonce, proof: proof)
    }
    var missing = ReceiverSession(pairingKey: key, hostID: "host-001")
    #expect(missing.hello(makeHello(nil, nil), busy: false, now: 0) == .rejected("Pair again"))
    var bad = ReceiverSession(pairingKey: key, hostID: "host-001")
    #expect(
      bad.hello(makeHello(nonce, String(repeating: "A", count: 44)), busy: false, now: 0)
        == .rejected("Pair again"))
    var valid = ReceiverSession(pairingKey: key, hostID: "host-001")
    #expect(valid.hello(makeHello(nonce, proof), busy: false, now: 0) == .accepted)
    let ack = valid.authenticatedHelloAck(deviceNonce: deviceNonce, hostNonce: hostNonce, host: nil)
    #expect(ack.nonce == PairingCrypto.base64(hostNonce))
    #expect(
      ack.proof.map {
        PairingCrypto.verifyHostProof(
          base64Proof: $0, pairKey: key, hostID: "host-001", base64DeviceNonce: nonce,
          base64HostNonce: ack.nonce!)
      } == true)
  }

  @Test func helloAckProofDoesNotReplayAcrossDeviceNonces() throws {
    let key = hex("cacc6ce751d9df5cedeb877f88b5270868b5c66deb5edb22159b000b365e1fc7")
    // A host proof recorded in an earlier session binds the old device nonce.
    let oldProof = PairingCrypto.hostProof(
      pairKey: key, hostID: "host-001", deviceNonce: deviceNonce, hostNonce: hostNonce)
    #expect(
      PairingCrypto.verifyHostProof(
        oldProof, pairKey: key, hostID: "host-001", deviceNonce: deviceNonce, hostNonce: hostNonce))
    let freshDeviceNonce = Data(repeating: 7, count: 32)
    #expect(
      !PairingCrypto.verifyHostProof(
        oldProof, pairKey: key, hostID: "host-001", deviceNonce: freshDeviceNonce,
        hostNonce: hostNonce))
    // The device-side session rejects the replayed ack against the new nonce.
    let session = SenderSession(pairKey: key, hostID: "host-001", deviceID: "device-001")
    let replayedAck = ControlMessage.HelloAck(
      accepted: true, udpPort: 0, displayWidth: 0, displayHeight: 0,
      nonce: PairingCrypto.base64(hostNonce),
      proof: PairingCrypto.base64(oldProof))
    #expect(!session.verifiesHelloAck(replayedAck, deviceNonce: freshDeviceNonce))
    #expect(session.verifiesHelloAck(replayedAck, deviceNonce: deviceNonce))
  }

  @Test func receiverSessionSupportsPerDeviceKeyUpdate() throws {
    let key = hex("cacc6ce751d9df5cedeb877f88b5270868b5c66deb5edb22159b000b365e1fc7")
    let nonce = PairingCrypto.base64(deviceNonce)
    let proof = PairingCrypto.base64(
      PairingCrypto.helloProof(pairKey: key, identifier: "device-001", nonce: deviceNonce))
    let hello = ControlMessage.Hello(
      appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 1, surfaceHeight: 1,
      nonce: nonce, proof: proof)
    var session = ReceiverSession(hostID: "host-001")
    #expect(session.hello(hello, busy: false, now: 0) == .rejected("Pair again"))
    session.updatePairingKey(key, hostID: "host-001")
    #expect(session.hello(hello, busy: false, now: 0) == .accepted)
    session.updatePairingKey(nil, hostID: "host-001")
    #expect(session.hello(hello, busy: false, now: 0) == .rejected("Pair again"))
  }
}

private func message(from event: PairingEvent) -> ControlMessage? {
  guard case .send(let message) = event else { return nil }
  return message
}

private func code(from event: PairingEvent) -> String? {
  guard case .showCode(let code) = event else { return nil }
  return code
}
