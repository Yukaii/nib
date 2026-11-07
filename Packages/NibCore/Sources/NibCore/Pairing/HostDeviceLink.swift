import Foundation

/// Testable per-connection hello policy for the host. Production
/// (`PenLinkReceiver`) routes every hello through this; tests drive it with
/// dummy `ObjectIdentifier`s, so the production path is exercised without
/// sockets.
///
/// An unpaired iPad (no stored key for `hello.deviceID`) gets
/// `helloAck{accepted:false, pairingRequired:true}` and the connection stays
/// open in a pairing-only state. In that state only hello, pairRequest,
/// pairReveal, pairResult and ping are processed: no samples, gestures or UDP
/// gate. After `paired`, the iPad sends a fresh authenticated hello on the
/// same connection, which is then accepted.
public struct HostLink: Sendable {
  public var session = ReceiverSession()
  public var sessionConnected = false
  /// Which connection is in pairing-only state, if any.
  public var pairingOnly: ObjectIdentifier?
  private var store: PairingKeyStore?
  private var hostID: String?
  private var fallbackKey: Data?

  public init(
    store: PairingKeyStore? = nil, hostID: String? = nil, fallbackKey: Data? = nil
  ) {
    self.store = store
    self.hostID = hostID
    self.fallbackKey = fallbackKey
    self.session = ReceiverSession(
      pairingKey: nil, hostID: hostID)
  }

  public func pairingKey(for deviceID: String) -> Data? {
    if let store { return store.key(for: deviceID) }
    return fallbackKey
  }

  public var requiresStore: Bool { store != nil }

  public enum HelloOutcome: Sendable, Equatable {
    case reject(ControlMessage.HelloAck, disconnect: Bool)
    case pairingRequired(ControlMessage.HelloAck)
    case needsAccept(ControlMessage.Hello)
    case busy(ControlMessage.HelloAck)
  }

  /// Pure hello decision used by production and tests.
  public mutating func receiveHello(
    _ hello: ControlMessage.Hello, connectionID: ObjectIdentifier, busy: Bool, now: TimeInterval,
    hostAppVersion: String = "unknown"
  ) -> HelloOutcome {
    // Version first: even unpaired iPads get a version rejection, not pairing.
    if hello.protocolVersion != ControlMessage.ProtocolVersion.control {
      let reason = ReceiverSession.versionMismatchReason(
        remoteProtocol: hello.protocolVersion, hostAppVersion: hostAppVersion)
      session.updatePairingKey(pairingKey(for: hello.deviceID), hostID: hostID)
      return .reject(.init(accepted: false, reason: reason), disconnect: true)
    }
    if busy || sessionConnected {
      return .busy(.init(accepted: false, reason: "busy"))
    }
    // Legacy opt-in off: no store means today's behaviour, no proofs.
    guard store != nil else {
      return .needsAccept(hello)
    }
    session.updatePairingKey(pairingKey(for: hello.deviceID), hostID: hostID)
    let key = pairingKey(for: hello.deviceID)
    // Unpaired: invite to pair on this same connection, keep it open.
    guard let key else {
      pairingOnly = connectionID
      let ack = ControlMessage.HelloAck(
        accepted: false, reason: "Pair with this Mac", pairingRequired: true)
      return .pairingRequired(ack)
    }
    // Paired: require a valid proof with exactly 32-byte nonce.
    guard session.verifiesPairingProof(hello) else {
      pairingOnly = nil
      _ = key
      return .reject(.init(accepted: false, reason: "Pair again"), disconnect: true)
    }
    // Authenticated and not busy: the caller runs its accept prompt, then
    // calls `acceptHello` to mint the host proof.
    pairingOnly = nil
    return .needsAccept(hello)
  }

  /// Called after the user accept prompt allows the hello. Returns the ack to
  /// send (with host proof when paired) and whether the session is now full.
  public mutating func acceptHello(
    _ hello: ControlMessage.Hello, now: TimeInterval, udpPort: UInt16, displayWidth: Double,
    displayHeight: Double, host: ControlMessage.HostInfo?
  ) -> ControlMessage.HelloAck {
    session.updatePairingKey(pairingKey(for: hello.deviceID), hostID: hostID)
    let decision = session.hello(
      protocolVersion: hello.protocolVersion, busy: false, acceptResult: true, now: now)
    guard decision == .accepted else {
      return .init(accepted: false, reason: "rejected")
    }
    sessionConnected = true
    pairingOnly = nil
    if session.requiresPairingAuthentication {
      let deviceNonceData =
        (hello.nonce.flatMap { Data(base64Encoded: $0) }) ?? PairingCrypto.randomNonce()
      return session.authenticatedHelloAck(
        deviceNonce: deviceNonceData, hostNonce: PairingCrypto.randomNonce(), accepted: true,
        udpPort: udpPort, displayWidth: displayWidth, displayHeight: displayHeight, host: host)
    } else {
      return .init(
        accepted: true, udpPort: udpPort, displayWidth: displayWidth, displayHeight: displayHeight,
        host: host)
    }
  }

  /// Whether a non-hello control message may be processed. In pairing-only,
  /// only pairRequest/pairReveal/pairResult/ping (and hello, handled above)
  /// are processed; samples, gestures, geometry and UDP are ignored.
  public func allows(_ message: ControlMessage, connectionID: ObjectIdentifier) -> Bool {
    guard let pairingOnly, pairingOnly == connectionID else {
      // Not pairing-only: full session gating is done by sessionConnected.
      return true
    }
    switch message {
    case .hello, .pairRequest, .pairReveal, .pairResult, .ping:
      return true
    case .pairResponse, .helloAck, .geometry, .probe, .probeReply, .gesture, .frontApp:
      return false
    }
  }

  public mutating func connectionLost(_ id: ObjectIdentifier) {
    if pairingOnly == id { pairingOnly = nil }
    // Full session loss is handled by the owner (session.disconnect).
  }

  public mutating func newConnection(_ id: ObjectIdentifier) {
    // A new connection never inherits pairing-only from an old one; the old
    // pairing machine is reset by the driver's newConnection.
    _ = id
  }

  public mutating func clearPairingOnly(_ id: ObjectIdentifier) {
    if pairingOnly == id { pairingOnly = nil }
  }
}

/// Testable per-connection helloAck policy for the device (Wi-Fi sender and USB
/// listener share it). Production routes every helloAck through this; tests
/// drive it without sockets.
///
/// When a key is held, `hostInfo` and the rejection reason are only trusted
/// after proof verification. An unauthenticated rejection is shown but never
/// deletes a stored key.
public struct DeviceLink: Sendable {
  private var store: PairingKeyStore?
  private var hostID: String?
  public var baseHello: ControlMessage.Hello?
  public var lastDeviceNonce: Data?
  /// Set when the host invites pairing on this connection.
  public var pairingRequired = false

  public init(
    store: PairingKeyStore? = nil, hostID: String? = nil, baseHello: ControlMessage.Hello? = nil
  ) {
    self.store = store
    self.hostID = hostID
    self.baseHello = baseHello
  }

  public mutating func updateStore(store: PairingKeyStore?, hostID: String?) {
    self.store = store
    self.hostID = hostID
  }

  public mutating func updateBaseHello(_ hello: ControlMessage.Hello) {
    baseHello = hello
  }

  private func storedKey() -> Data? {
    guard let store, let hostID else { return nil }
    return store.key(for: hostID)
  }

  public var requiresAuthentication: Bool { storedKey() != nil }

  /// Fresh hello for the current connection. After `paired`, the caller sends
  /// this on the same connection.
  public mutating func makeHello() -> ControlMessage.Hello {
    let base =
      baseHello ?? .init(appVersion: "", deviceName: "NibPad", surfaceWidth: 0, surfaceHeight: 0)
    guard let store, let hostID, let pairKey = store.key(for: hostID) else {
      lastDeviceNonce = nil
      pairingRequired = false
      return base
    }
    let nonce = PairingCrypto.randomNonce()
    lastDeviceNonce = nonce
    var authenticated = base
    authenticated.nonce = PairingCrypto.base64(nonce)
    authenticated.proof = PairingCrypto.base64(
      PairingCrypto.helloProof(pairKey: pairKey, identifier: base.deviceID, nonce: nonce))
    return authenticated
  }

  public enum AckOutcome: Sendable, Equatable {
    case connected(hostInfo: ControlMessage.HostInfo?)
    case pairingRequired(reason: String, hostInfo: ControlMessage.HostInfo?)
    case rejected(reason: String, hostInfo: ControlMessage.HostInfo?, retryLater: Bool)
    case invalidProof
  }

  public mutating func receiveHelloAck(_ ack: ControlMessage.HelloAck) -> AckOutcome {
    let keyHeld = requiresAuthentication
    // Pairing invitation: unauthenticated, keep the connection open.
    if !ack.accepted, ack.pairingRequired == true {
      pairingRequired = true
      // Show the reason/host, but never delete a stored key on this basis.
      return .pairingRequired(reason: ack.reason ?? "Pair with this Mac", hostInfo: ack.host)
    }
    pairingRequired = false
    if ack.accepted {
      if keyHeld {
        // Verify before trusting hostInfo.
        guard let deviceNonce = lastDeviceNonce,
          let session = makeSession(),
          session.verifiesHelloAck(ack, deviceNonce: deviceNonce)
        else {
          return .invalidProof
        }
        return .connected(hostInfo: ack.host)
      } else {
        return .connected(hostInfo: ack.host)
      }
    } else {
      // Rejection.
      if keyHeld {
        // Unauthenticated rejection: show it, but never delete the key and
        // never trust hostInfo without a proof (there is none on reject).
        let reason = ack.reason ?? "rejected"
        let retry = PenLinkRejectionPolicy.decision(reason: ack.reason) == .retryLater
        return .rejected(reason: reason, hostInfo: nil, retryLater: retry)
      } else {
        let reason = ack.reason ?? "rejected"
        let retry = PenLinkRejectionPolicy.decision(reason: ack.reason) == .retryLater
        return .rejected(reason: reason, hostInfo: ack.host, retryLater: retry)
      }
    }
  }

  private func makeSession() -> SenderSession? {
    guard let store, let hostID else { return nil }
    let key = store.key(for: hostID)
    return SenderSession(pairKey: key, hostID: hostID, deviceID: baseHello?.deviceID)
  }
}
