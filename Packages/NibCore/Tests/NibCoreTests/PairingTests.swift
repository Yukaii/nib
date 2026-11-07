import Foundation
import NibCore
import Testing

private func hex(_ value: String) -> Data {
  Data(
    stride(from: 0, to: value.count, by: 2).map {
      UInt8(value.dropFirst($0).prefix(2), radix: 16)!
    })
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
    let proof = PairingCrypto.helloProof(pairKey: pairKey, identifier: "device-001", nonce: deviceNonce)
    #expect(proof == hex("c68a8a2b651ea2336fd1d356fe765aff59adab66495cac6272178cb87d6a5d28"))
    #expect(
      PairingCrypto.verifyHelloProof(proof, pairKey: pairKey, identifier: "device-001", nonce: deviceNonce))
    #expect(
      !PairingCrypto.verifyHelloProof(
        proof, pairKey: Data(repeating: 0, count: 32), identifier: "device-001", nonce: deviceNonce))
    #expect(
      PairingCrypto.numericCode(
        for: try PairingTranscript(
          devicePublicKey: device.publicKey, hostPublicKey: host.publicKey,
          deviceNonce: Data(repeating: 0, count: 32), hostNonce: hostNonce)) != "463962")
  }

  @Test func pairingMessagesAndAuthenticatedHelloRoundTrip() throws {
    let messages: [ControlMessage] = [
      .pairRequest(.init(deviceID: "device", deviceName: "iPad", publicKey: "key", nonce: "nonce")),
      .pairResponse(.init(hostID: "host", hostName: "Mac", publicKey: "key", nonce: "nonce")),
      .pairResult(.init(accepted: false, reason: "Pair again")),
      .hello(
        .init(
          appVersion: "0.3.0", deviceID: "device", deviceName: "iPad", surfaceWidth: 1,
          surfaceHeight: 2, nonce: "nonce", proof: "proof")),
      .helloAck(.init(accepted: true, nonce: "nonce", proof: "proof")),
    ]
    for message in messages {
      var framer = ControlFramer()
      #expect(try framer.append(framer.encode(message)) == [message])
    }
  }

  @Test func pairingStateMachineStoresOnlyAfterBothConfirm() throws {
    let deviceStore = InMemoryPairingKeyStore()
    let hostStore = InMemoryPairingKeyStore()
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad", keyPair: try PairingKeyPair(privateKey: devicePrivate),
      store: deviceStore)
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    let request = try #require(try device.begin(nonce: deviceNonce))
    let responseEvents = host.receive(try #require(message(from: request)))
    let response = try #require(responseEvents.compactMap(message).first)
    let hostCode = try #require(responseEvents.compactMap(code).first)
    let deviceCode = try #require(device.receive(response).compactMap(code).first)
    #expect(deviceCode == hostCode)
    #expect(deviceStore.key(for: "host-001") == nil)
    #expect(hostStore.key(for: "device-001") == nil)
    let deviceResult = try #require(device.confirm().compactMap(message).first)
    #expect(host.receive(deviceResult).isEmpty)
    #expect(hostStore.key(for: "device-001") == nil)
    let hostResult = try #require(host.confirm().compactMap(message).first)
    #expect(host.phase == .paired)
    #expect(device.receive(hostResult).contains(.paired(peerID: "host-001")))
    #expect(device.phase == .paired)
    #expect(deviceStore.key(for: "host-001") != nil)
    #expect(hostStore.key(for: "device-001") != nil)
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
    let responseEvents = host.receive(try #require(message(from: request)))
    let response = try #require(responseEvents.compactMap(message).first)
    #expect(device.receive(response).compactMap(code).first != nil)
    // Host cancels locally: emits a rejection and stores nothing.
    let hostCancel = host.cancel()
    guard case .send(let cancelMessage) = hostCancel else {
      Issue.record("host cancel must send a pairResult")
      return
    }
    #expect(host.phase == .cancelled)
    #expect(hostStore.key(for: "device-001") == nil)
    // The peer observes the rejection and stores nothing either.
    #expect(device.receive(cancelMessage) == [.cancelled])
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
    let ack = valid.authenticatedHelloAck(for: hostNonce, host: nil)
    #expect(ack.nonce == PairingCrypto.base64(hostNonce))
    #expect(
      ack.proof.map {
        PairingCrypto.verifyHelloProof(
          base64Proof: $0, pairKey: key, identifier: "host-001", base64Nonce: ack.nonce!)
      } == true)
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
