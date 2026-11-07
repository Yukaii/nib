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

private final class FakeConn {}

private final class FailingPairingKeyStore: PairingKeyStore, @unchecked Sendable {
  func key(for peerID: String) -> Data? { nil }
  @discardableResult func save(_ key: Data, for peerID: String) -> Bool { false }
  func removeKey(for peerID: String) {}
}

struct PairingTests {
  private let devicePrivate = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
  private let hostPrivate = hex("2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40")
  private let deviceNonce = hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
  private let hostNonce = hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf")
  private let helloDeviceNonce = hex(
    "e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
  private let helloHostNonce = hex(
    "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f")

  @Test func cryptoBindsIdentitiesAndLabelsArePrefixFree() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let transcript = try PairingTranscript(
      deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey, deviceNonce: deviceNonce, hostNonce: hostNonce)
    // Changing either ID changes the code: a relay cannot relabel.
    let relabeled = try PairingTranscript(
      deviceID: "device-002", hostID: "host-001", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey, deviceNonce: deviceNonce, hostNonce: hostNonce)
    #expect(PairingCrypto.numericCode(for: relabeled) != PairingCrypto.numericCode(for: transcript))
    let relabeledHost = try PairingTranscript(
      deviceID: "device-001", hostID: "host-002", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey, deviceNonce: deviceNonce, hostNonce: hostNonce)
    #expect(
      PairingCrypto.numericCode(for: relabeledHost) != PairingCrypto.numericCode(for: transcript))
    // Commitment binds the deviceID.
    let commitment = PairingCrypto.commitment(
      deviceID: "device-001", publicKey: device.publicKey, nonce: deviceNonce)
    #expect(
      PairingCrypto.verifyCommitment(
        commitment, deviceID: "device-001", publicKey: device.publicKey, nonce: deviceNonce))
    #expect(
      !PairingCrypto.verifyCommitment(
        commitment, deviceID: "device-002", publicKey: device.publicKey, nonce: deviceNonce))
    #expect(
      !PairingCrypto.verifyCommitment(
        commitment, deviceID: "device-001", publicKey: device.publicKey, nonce: Data(repeating: 0, count: 32))
    )
    // Labels are prefix-free.
    #expect(PairingCrypto.areLabelsPrefixFree())
    // Proofs require exactly 32-byte nonces.
    let pairKey = try PairingCrypto.pairKey(
      privateKey: devicePrivate, peerPublicKey: host.publicKey, transcript: transcript)
    let deviceProof = PairingCrypto.helloProof(
      pairKey: pairKey, identifier: "device-001", nonce: helloDeviceNonce)
    #expect(
      PairingCrypto.verifyHelloProof(
        deviceProof, pairKey: pairKey, identifier: "device-001", nonce: helloDeviceNonce))
    #expect(
      !PairingCrypto.verifyHelloProof(
        deviceProof, pairKey: pairKey, identifier: "device-001",
        nonce: Data(helloDeviceNonce.prefix(31))))
    #expect(
      !PairingCrypto.verifyHelloProof(
        Data(repeating: 0, count: 31), pairKey: pairKey, identifier: "device-001",
        nonce: helloDeviceNonce))
    let hostProof = PairingCrypto.hostProof(
      pairKey: pairKey, hostID: "host-001", deviceNonce: helloDeviceNonce, hostNonce: helloHostNonce)
    #expect(
      PairingCrypto.verifyHostProof(
        hostProof, pairKey: pairKey, hostID: "host-001", deviceNonce: helloDeviceNonce,
        hostNonce: helloHostNonce))
    #expect(
      !PairingCrypto.verifyHostProof(
        hostProof, pairKey: pairKey, hostID: "host-001", deviceNonce: Data(repeating: 0, count: 31),
        hostNonce: helloHostNonce))
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
      .helloAck(.init(accepted: false, reason: "Pair with this Mac", pairingRequired: true)),
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
    guard case .pairRequest(let request) = try framerRoundTrip(requestMessage) else {
      Issue.record("expected pairRequest on the wire")
      return
    }
    #expect(request.commitment.count > 0)
    if let nonceData = Data(base64Encoded: request.commitment) {
      #expect(nonceData != deviceNonce)
    }
    let responseEvents = host.receive(try framerRoundTrip(requestMessage))
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

  @Test func secondPairRequestMidFlowIsIgnored() throws {
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: InMemoryPairingKeyStore())
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    let first = try #require(try device.begin(nonce: deviceNonce))
    let firstMsg = try #require(message(from: first))
    _ = host.receive(try framerRoundTrip(firstMsg))
    #expect(host.phase == .waitingForReveal)
    // A stray second pairRequest from another iPad must not abort pairing.
    var device2 = PairingStateMachine(
      role: .device, id: "device-002", name: "iPad 2",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    let second = try #require(try device2.begin(nonce: hostNonce))
    let secondMsg = try #require(message(from: second))
    let secondOnWire = try framerRoundTrip(secondMsg)
    #expect(host.receive(secondOnWire).isEmpty)
    #expect(host.phase == .waitingForReveal)
  }

  @Test func earlyAndDuplicatePairResultsAreIgnored() throws {
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    // Early pairResult with no pairing in progress is ignored.
    #expect(device.receive(.pairResult(.init(accepted: false))).isEmpty)
    #expect(device.phase == .idle)
    #expect(device.receive(.pairResult(.init(accepted: true))).isEmpty)
    // Happy path to paired, then duplicate rejections are ignored.
    let hostStore = InMemoryPairingKeyStore()
    let deviceStore = InMemoryPairingKeyStore()
    var fullDevice = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: deviceStore)
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    let req = try #require(try fullDevice.begin(nonce: deviceNonce))
    let reqMsg = try #require(message(from: req))
    let reqWire = try framerRoundTrip(reqMsg)
    let resp = try #require(host.receive(reqWire).compactMap(message).first)
    let devEvents = fullDevice.receive(try framerRoundTrip(resp))
    let reveal = try #require(devEvents.compactMap(message).first)
    _ = host.receive(try framerRoundTrip(reveal))
    let devConfirm = try #require(fullDevice.confirm().compactMap(message).first)
    #expect(host.receive(try framerRoundTrip(devConfirm)).isEmpty)
    let hostConfirm = try #require(host.confirm().compactMap(message).first)
    #expect(host.phase == .paired)
    let devPaired = fullDevice.receive(try framerRoundTrip(hostConfirm))
    #expect(devPaired.contains(.paired(peerID: "host-001")))
    #expect(fullDevice.phase == .paired)
    #expect(host.phase == .paired)
    #expect(fullDevice.receive(.pairResult(.init(accepted: false))).isEmpty)
    #expect(host.receive(.pairResult(.init(accepted: false))).isEmpty)
    #expect(fullDevice.phase == .paired)
  }

  @Test func wrongRevealFailsStoresNothingAndIsTerminal() throws {
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
    let badReveal = ControlMessage.pairReveal(
      .init(nonce: PairingCrypto.base64(Data(repeating: 0, count: 32))))
    let result = host.receive(try framerRoundTrip(badReveal))
    #expect(result.count == 1)
    guard case .failed = result.first else {
      Issue.record("wrong reveal must fail pairing, got \(result)")
      return
    }
    #expect(host.phase == .failed)
    #expect(host.isTerminal)
    #expect(hostStore.key(for: "device-001") == nil)
    #expect(deviceStore.key(for: "host-001") == nil)
  }

  @Test func tamperedKeyOrNonceChangesCode() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let baseline = try PairingTranscript(
      deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey,
      deviceNonce: deviceNonce, hostNonce: hostNonce)
    let baselineCode = PairingCrypto.numericCode(for: baseline)
    var tamperedKey = host.publicKey
    tamperedKey[0] ^= 0x01
    let tamperedKeyCode = PairingCrypto.numericCode(
      for: try PairingTranscript(
        deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
        hostPublicKey: tamperedKey,
        deviceNonce: deviceNonce, hostNonce: hostNonce))
    #expect(tamperedKeyCode != baselineCode)
    let tamperedNonceCode = PairingCrypto.numericCode(
      for: try PairingTranscript(
        deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
        hostPublicKey: host.publicKey,
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

  @Test func failedKeyStoreDoesNotReportPaired() throws {
    let deviceStore = FailingPairingKeyStore()
    let hostStore = InMemoryPairingKeyStore()
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad", keyPair: try PairingKeyPair(privateKey: devicePrivate),
      store: deviceStore)
    var host = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac", keyPair: try PairingKeyPair(privateKey: hostPrivate),
      store: hostStore)
    let request = try #require(try device.begin(nonce: deviceNonce))
    let requestMessage = try #require(message(from: request))
    let responseEvents = host.receive(try framerRoundTrip(requestMessage))
    let response = try #require(responseEvents.compactMap(message).first)
    let deviceEvents = device.receive(try framerRoundTrip(response))
    let reveal = try #require(deviceEvents.compactMap(message).first)
    _ = host.receive(try framerRoundTrip(reveal))
    let deviceResult = try #require(device.confirm().compactMap(message).first)
    _ = host.receive(try framerRoundTrip(deviceResult))
    let hostResult = try #require(host.confirm().compactMap(message).first)
    let events = device.receive(try framerRoundTrip(hostResult))
    #expect(events.contains(.failed("Couldn't save the pairing key. Try pairing again.")))
    #expect(!events.contains { if case .paired = $0 { true } else { false } })
    #expect(device.phase == .failed)
    #expect(deviceStore.key(for: "host-001") == nil)
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
    let hostCancel = host.cancel()
    guard case .send(let cancelMessage) = hostCancel else {
      Issue.record("host cancel must send a pairResult")
      return
    }
    #expect(host.phase == .cancelled)
    #expect(hostStore.key(for: "device-001") == nil)
    #expect(device.receive(try framerRoundTrip(cancelMessage)) == [.cancelled])
    #expect(device.phase == .cancelled)
    #expect(deviceStore.key(for: "host-001") == nil)
  }

  @Test func receiverPolicyThroughHostLink() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let transcript = try PairingTranscript(
      deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey, deviceNonce: helloDeviceNonce, hostNonce: helloHostNonce)
    let pairKey = try PairingCrypto.pairKey(
      privateKey: devicePrivate, peerPublicKey: host.publicKey, transcript: transcript)
    // Production path: HostLink.receiveHello, not the removed overload.
    var link = HostLink(
      store: {
        let s = InMemoryPairingKeyStore()
        s.save(pairKey, for: "device-001")
        return s
      }(), hostID: "host-001")
    let nonce = PairingCrypto.base64(helloDeviceNonce)
    let proof = PairingCrypto.base64(
      PairingCrypto.helloProof(pairKey: pairKey, identifier: "device-001", nonce: helloDeviceNonce))
    func hello(nonce: String?, proof: String?) -> ControlMessage.Hello {
      .init(
        appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 1,
        surfaceHeight: 1, nonce: nonce, proof: proof)
    }
    // Missing proof → reject, disconnect.
    if case .reject(let ack, let disconnect) = link.receiveHello(
      hello(nonce: nil, proof: nil), connectionGeneration: 1, busy: false, now: 0)
    {
      #expect(ack.accepted == false)
      #expect(disconnect)
    } else {
      Issue.record("missing proof must reject")
    }
    // Bad proof → reject.
    if case .reject = link.receiveHello(
      hello(nonce: nonce, proof: String(repeating: "A", count: 44)), connectionGeneration: 1, busy: false,
      now: 0)
    {
    } else {
      Issue.record("bad proof must reject")
    }
    // Valid proof → authenticated (no accept prompt), then acceptHello mints a
    // verifiable host proof.
    if case .authenticated(let h) = link.receiveHello(
      hello(nonce: nonce, proof: proof), connectionGeneration: 1, busy: false, now: 0)
    {
      let ack = link.acceptHello(
        h, now: 0, udpPort: 0, displayWidth: 0, displayHeight: 0, host: nil)
      #expect(ack.accepted)
      #expect(
        ack.proof.map {
          PairingCrypto.verifyHostProof(
            base64Proof: $0, pairKey: pairKey, hostID: "host-001",
            base64DeviceNonce: nonce, base64HostNonce: ack.nonce!)
        } == true)
    } else {
      Issue.record("valid proof must need accept")
    }
  }

  @Test func helloAckProofDoesNotReplayAcrossDeviceNonces() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let transcript = try PairingTranscript(
      deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey, deviceNonce: deviceNonce, hostNonce: hostNonce)
    let key = try PairingCrypto.pairKey(
      privateKey: devicePrivate, peerPublicKey: host.publicKey, transcript: transcript)
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
    let session = SenderSession(pairKey: key, hostID: "host-001", deviceID: "device-001")
    let replayedAck = ControlMessage.HelloAck(
      accepted: true, udpPort: 0, displayWidth: 0, displayHeight: 0,
      nonce: PairingCrypto.base64(hostNonce),
      proof: PairingCrypto.base64(oldProof))
    #expect(!session.verifiesHelloAck(replayedAck, deviceNonce: freshDeviceNonce))
    #expect(session.verifiesHelloAck(replayedAck, deviceNonce: deviceNonce))
  }

  @Test func unpairedHelloInvitesPairingAndFreshHelloIsAccepted() throws {
    // End-to-end through the production hello policies and state machines:
    // fresh pairing over an in-memory transport, then an authenticated hello.
    let deviceStore = InMemoryPairingKeyStore()
    let hostStore = InMemoryPairingKeyStore()
    var hostLink = HostLink(store: hostStore, hostID: "host-001")
    var deviceLink = DeviceLink(
      store: deviceStore, hostID: "host-001",
      baseHello: .init(
        appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 100,
        surfaceHeight: 100))
    // Unpaired hello → pairingRequired, connection stays open.
    let unpaired = ControlMessage.Hello(
      appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 100,
      surfaceHeight: 100)
    guard
      case .pairingRequired(let ack) = hostLink.receiveHello(
        unpaired, connectionGeneration: 1, busy: false, now: 0)
    else {
      Issue.record("unpaired hello must invite pairing")
      return
    }
    #expect(ack.pairingRequired == true)
    #expect(hostLink.pairingOnlyGeneration == 1)
    // Pairing-only gating: only pair*/ping pass.
    #expect(
      hostLink.allows(
        .pairRequest(.init(deviceID: "d", deviceName: "n", publicKey: "k", commitment: "c")),
        connectionGeneration: 1
      ))
    #expect(!hostLink.allows(.gesture(.undo), connectionGeneration: 1))
    #expect(!hostLink.allows(.geometry(.init(surfaceWidth: 1, surfaceHeight: 1)), connectionGeneration: 1))
    // Full commit-reveal through the framer.
    var deviceMachine = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: deviceStore)
    var hostMachine = PairingStateMachine(
      role: .host, id: "host-001", name: "Mac",
      keyPair: try PairingKeyPair(privateKey: hostPrivate), store: hostStore)
    let reqEvent = try #require(try deviceMachine.begin(nonce: deviceNonce))
    let reqMsg0 = try #require(message(from: reqEvent))
    let reqMsg = try framerRoundTrip(reqMsg0)
    let respEvents = hostMachine.receive(reqMsg)
    let respMsg = try #require(respEvents.compactMap(message).first)
    let devEvents = deviceMachine.receive(try framerRoundTrip(respMsg))
    let revealMsg = try #require(devEvents.compactMap(message).first)
    _ = hostMachine.receive(try framerRoundTrip(revealMsg))
    let devConfirmMsg = try #require(deviceMachine.confirm().compactMap(message).first)
    #expect(hostMachine.receive(try framerRoundTrip(devConfirmMsg)).isEmpty)
    let hostConfirmMsg = try #require(hostMachine.confirm().compactMap(message).first)
    #expect(hostMachine.phase == .paired)
    let devPaired = deviceMachine.receive(try framerRoundTrip(hostConfirmMsg))
    #expect(devPaired.contains(.paired(peerID: "host-001")))
    #expect(deviceMachine.phase == .paired)
    #expect(hostStore.key(for: "device-001") != nil)
    // After paired, the iPad sends a fresh authenticated hello on the same
    // connection; the host accepts it.
    let fresh = deviceLink.makeHello()
    #expect(fresh.nonce != nil)
    guard
      case .authenticated(let h) = hostLink.receiveHello(
        fresh, connectionGeneration: 1, busy: false, now: 1)
    else {
      Issue.record("fresh authenticated hello must be accepted without a prompt")
      return
    }
    let acceptedAck = hostLink.acceptHello(
      h, now: 1, udpPort: 0, displayWidth: 0, displayHeight: 0, host: nil)
    #expect(acceptedAck.accepted)
    // Device verifies the host proof (DeviceLink ordering: verify before trust).
    let outcome = deviceLink.receiveHelloAck(acceptedAck)
    if case .connected = outcome {
    } else {
      Issue.record("device must connect on verified ack, got \(outcome)")
    }
    hostLink.clearPairingOnly(1)
    #expect(hostLink.pairingOnlyGeneration == nil)
  }

  @Test func deviceLinkOrdersVerificationBeforeTrust() throws {
    let device = try PairingKeyPair(privateKey: devicePrivate)
    let host = try PairingKeyPair(privateKey: hostPrivate)
    let transcript = try PairingTranscript(
      deviceID: "device-001", hostID: "host-001", devicePublicKey: device.publicKey,
      hostPublicKey: host.publicKey, deviceNonce: deviceNonce, hostNonce: hostNonce)
    let pairKey = try PairingCrypto.pairKey(
      privateKey: devicePrivate, peerPublicKey: host.publicKey, transcript: transcript)
    let store = InMemoryPairingKeyStore()
    store.save(pairKey, for: "host-001")
    var link = DeviceLink(
      store: store, hostID: "host-001",
      baseHello: .init(
        appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 1,
        surfaceHeight: 1))
    _ = link.makeHello()
    // Invalid proof → invalidProof, no hostInfo trusted.
    let badAck = ControlMessage.HelloAck(
      accepted: true, udpPort: 1, displayWidth: 1, displayHeight: 1,
      host: .init(platform: .macos, name: "Evil", appVersion: "9", capabilities: []),
      nonce: PairingCrypto.base64(hostNonce),
      proof: PairingCrypto.base64(Data(repeating: 0, count: 32)))
    if case .invalidProof = link.receiveHelloAck(badAck) {
    } else {
      Issue.record("bad proof must be invalidProof")
    }
    // Unauthenticated rejection while a key is held: shown, but hostInfo not
    // trusted and the stored key is never deleted on this basis.
    let rejection = ControlMessage.HelloAck(accepted: false, reason: "Pair again")
    if case .rejected(let reason, let info, _) = link.receiveHelloAck(rejection) {
      #expect(reason == "Pair again")
      #expect(info == nil)
    } else {
      Issue.record("rejection must be .rejected without trusted hostInfo")
    }
    #expect(store.key(for: "host-001") != nil)
  }

  @Test func attemptLimiterBlocksAfterThreeFailures() throws {
    var limiter = PairingAttemptLimiter()
    #expect(limiter.canAttempt(at: 0))
    limiter.recordFailure(at: 0)
    limiter.recordFailure(at: 60)
    limiter.recordFailure(at: 120)
    #expect(!limiter.canAttempt(at: 130))
    // After 60 s from the last failure, attempts resume.
    #expect(limiter.canAttempt(at: 200))
    // Old failures outside the 5-minute window do not count.
    var fresh = PairingAttemptLimiter()
    fresh.recordFailure(at: 0)
    #expect(fresh.canAttempt(at: 400))
  }

  @Test @MainActor func pairingDriverBindsToConnection() throws {
    let store = InMemoryPairingKeyStore()
    let driver = PairingDriver(role: .host, localID: "host-001", localName: { "Mac" }, store: store)
    var sent: [ControlMessage] = []
    var events: [PairingTransportEvent] = []
    driver.onSend = { sent.append($0) }
    driver.onEvent = { events.append($0) }
    // New connection never inherits: begin on A, then B's pairRequest ignored.
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    let reqEvent = try #require(try device.begin(nonce: deviceNonce))
    guard case .send(let reqMsg) = reqEvent else {
      Issue.record("begin must send")
      return
    }
    driver.receive(reqMsg, connectionGeneration: 1)
    #expect(driver.phase == .waitingForReveal)
    #expect(sent.count == 1)
    // A second connection's pairRequest mid-flow is ignored (no new send).
    var device2 = PairingStateMachine(
      role: .device, id: "device-002", name: "iPad 2",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    let req2 = try #require(try device2.begin(nonce: hostNonce))
    guard case .send(let reqMsg2) = req2 else { return }
    driver.receive(reqMsg2, connectionGeneration: 2)
    #expect(sent.count == 1)
    // A .send never goes to a different connection: confirm on B does nothing.
    driver.confirm(connectionGeneration: 2)
    #expect(events.isEmpty)
    // Loss of A resets; B can now start fresh.
    driver.connectionLost(1)
    #expect(driver.phase == nil)
    driver.receive(reqMsg2, connectionGeneration: 2)
    #expect(driver.phase == .waitingForReveal)
    #expect(sent.count == 2)
  }

  @Test func pairingOnlyConnectionHasNoIdleDeadline() throws {
    var link = HostLink(store: InMemoryPairingKeyStore(), hostID: "host-001")
    let hello = ControlMessage.Hello(
      appVersion: "0.3.0", deviceID: "device-001", deviceName: "iPad", surfaceWidth: 1,
      surfaceHeight: 1)
    guard
      case .pairingRequired = link.receiveHello(
        hello, connectionGeneration: 41, busy: false, now: 100)
    else {
      Issue.record("unpaired hello must enter pairing-only")
      return
    }
    // A human may take longer than ten seconds before tapping Pair.
    #expect(link.pairingOnlyGeneration == 41)
    #expect(link.allows(.ping, connectionGeneration: 41))
    #expect(
      link.allows(
        .pairRequest(.init(deviceID: "d", deviceName: "n", publicKey: "k", commitment: "c")),
        connectionGeneration: 41))
    // A generation replacement clears the policy state explicitly.
    link.newConnection(42)
    #expect(link.pairingOnlyGeneration == nil)
  }

  @Test @MainActor func attemptLimitRefusalUsesRequestingGeneration() throws {
    let driver = PairingDriver(
      role: .host, localID: "host-001", localName: { "Mac" }, store: InMemoryPairingKeyStore())
    driver.clock = { 100 }
    let failedRequest = ControlMessage.pairRequest(
      .init(deviceID: "device-001", deviceName: "iPad", publicKey: "bad", commitment: "bad"))
    for generation in 1...PairingAttemptLimiter.maxFailures {
      driver.receive(failedRequest, connectionGeneration: UInt64(generation))
    }
    var sent: (ControlMessage, UInt64)?
    driver.onSendUnbound = { sent = ($0, $1) }
    let request = ControlMessage.pairRequest(
      .init(deviceID: "device-001", deviceName: "iPad", publicKey: "key", commitment: "commit"))
    driver.receive(request, connectionGeneration: 77)
    guard case .pairResult(let result)? = sent?.0 else {
      Issue.record("attempt-limit refusal must reach the requesting connection")
      return
    }
    #expect(!result.accepted)
    #expect(sent?.1 == 77)
    #expect(driver.phase == nil)
  }

  @Test @MainActor func busyRetriesDoNotConsumeFailureBudget() throws {
    let driver = PairingDriver(
      role: .host, localID: "host-001", localName: { "Mac" }, store: InMemoryPairingKeyStore())
    driver.clock = { 100 }
    var device = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad",
      keyPair: try PairingKeyPair(privateKey: devicePrivate), store: InMemoryPairingKeyStore())
    let beginEvent = try #require(try device.begin(nonce: deviceNonce))
    let active = try #require(message(from: beginEvent))
    driver.receive(active, connectionGeneration: 1)
    #expect(driver.phase == .waitingForReveal)
    // Busy newcomers never reach the driver, so these displaced retries do
    // not consume its failure budget.
    for _ in 0..<20 { driver.receive(active, connectionGeneration: 2) }
    #expect(driver.phase == .waitingForReveal)
    driver.cancel(connectionGeneration: 1)
    // One cancellation is below the refusal threshold.
    var refusal: ControlMessage?
    driver.onSendUnbound = { message, _ in refusal = message }
    driver.receive(active, connectionGeneration: 3)
    #expect(refusal == nil)
  }

  @Test @MainActor func threeCancelledMachinesTriggerLimiter() throws {
    let driver = PairingDriver(
      role: .host, localID: "host-001", localName: { "Mac" }, store: InMemoryPairingKeyStore())
    driver.clock = { 100 }
    let device = try PairingKeyPair(privateKey: devicePrivate)
    var machine = PairingStateMachine(
      role: .device, id: "device-001", name: "iPad", keyPair: device,
      store: InMemoryPairingKeyStore())
    let beginEvent = try #require(try machine.begin(nonce: deviceNonce))
    let request = try #require(message(from: beginEvent))
    for generation in 1...3 {
      driver.receive(request, connectionGeneration: UInt64(generation))
      #expect(driver.phase == .waitingForReveal)
      driver.cancel(connectionGeneration: UInt64(generation))
    }
    var refusal: ControlMessage?
    driver.onSendUnbound = { message, _ in refusal = message }
    driver.receive(request, connectionGeneration: 4)
    guard case .pairResult(let result)? = refusal else {
      Issue.record("three cancelled pairings must refuse the next request")
      return
    }
    #expect(result.reason?.contains("Too many pairing attempts") == true)
  }

  @Test func pairingRequiredAckDoesNotPublishUntrustedHostInfo() throws {
    let store = InMemoryPairingKeyStore()
    store.save(Data(repeating: 7, count: 32), for: "host-001")
    var link = DeviceLink(store: store, hostID: "host-001")
    let evilHost = ControlMessage.HostInfo(
      platform: .macos, name: "Evil Mac", appVersion: "9", capabilities: [])
    let outcome = link.receiveHelloAck(
      .init(accepted: false, reason: "Pair again", host: evilHost, pairingRequired: true))
    guard case .pairingRequired(let reason, let info) = outcome else {
      Issue.record("pairingRequired must remain a visible hint")
      return
    }
    #expect(reason == "Pair again")
    #expect(info == nil)
    #expect(store.key(for: "host-001") != nil)
  }

  @Test func pairingOnlyDeviceIgnoresProbeAndFrontApp() {
    var link = DeviceLink()
    link.pairingRequired = true
    #expect(!link.allows(.probe(sentAtNs: 1)))
    #expect(!link.allows(.frontApp(.init(appID: "evil", name: "Evil"))))
    #expect(link.allows(.ping))
    #expect(link.allows(.pairResult(.init(accepted: false))))
  }

  @Test func extractedDispatchersPumpProductionFramers() throws {
    final class MemoryTransport: LinkByteTransport, @unchecked Sendable {
      var bytes: [Data] = []
      var closed = false
      func send(bytes: Data) { self.bytes.append(bytes) }
      func close() { closed = true }
    }
    final class Box<T>: @unchecked Sendable {
      var value: T
      init(_ value: T) { self.value = value }
    }
    let controlTransport = MemoryTransport()
    let controls = Box<[ControlMessage]>([])
    let control = ControlLinkDispatcher(transport: controlTransport) { controls.value.append($0) }
    let controlBytes = ControlFramer().encode(.ping) + ControlFramer().encode(.probe(sentAtNs: 3))
    try control.receive(Data(controlBytes))
    #expect(controls.value == [.ping, .probe(sentAtNs: 3)])
    control.send(.ping)
    var controlDecoder = ControlFramer()
    #expect(try controlDecoder.append(Array(controlTransport.bytes[0])) == [.ping])

    let streamTransport = MemoryTransport()
    let streamControls = Box<[ControlMessage]>([])
    let samples = Box<[PenSample]>([])
    let stream = StreamLinkDispatcher(
      transport: streamTransport, onControl: { streamControls.value.append($0) },
      onSample: { samples.value.append($0) })
    let sample = PenSample(
      kind: .move, sequence: 1, timestamp: 2, x: 0.5, y: 0.5, pressure: 0.7, altitude: 1,
      azimuth: 2)
    try stream.receive(Data(StreamFramer.encode(.control(.ping)) + StreamFramer.encode(.sample(sample))))
    #expect(streamControls.value == [.ping])
    #expect(samples.value == [sample])
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
