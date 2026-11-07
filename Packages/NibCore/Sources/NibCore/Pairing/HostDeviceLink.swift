import Foundation

public final class DeviceSessionArm: @unchecked Sendable {
  private let lock = NSLock()
  private var pairKey: Data?
  private var deviceNonce: Data?
  private var hostID: String = ""
  func prepare(pairKey: Data, deviceNonce: Data, hostID: String) {
    lock.lock()
    self.pairKey = pairKey
    self.deviceNonce = deviceNonce
    self.hostID = hostID
    lock.unlock()
  }
  func clear() {
    lock.lock()
    pairKey = nil
    deviceNonce = nil
    lock.unlock()
  }
  func make(_ ack: ControlMessage.HelloAck) -> SessionCipher? {
    lock.lock()
    let key = pairKey
    let nonce = deviceNonce
    let id = hostID
    lock.unlock()
    guard ack.accepted, let key, let nonce, let hostNonceString = ack.nonce,
      let hostNonce = Data(base64Encoded: hostNonceString), let proof = ack.proof,
      PairingCrypto.verifyHostProof(
        base64Proof: proof, pairKey: key, hostID: id, base64DeviceNonce: PairingCrypto.base64(nonce),
        base64HostNonce: hostNonceString)
    else { return nil }
    return try? SessionCipher(pairKey: key, ipadNonce: nonce, hostNonce: hostNonce, role: .device)
  }
}

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
  public private(set) var pairingOnlyGeneration: UInt64?
  private var store: PairingKeyStore?
  private var hostID: String?
  private var fallbackKey: Data?
  public private(set) var sessionParameters: SessionParameters?

  public init(
    store: PairingKeyStore? = nil, hostID: String? = nil, fallbackKey: Data? = nil
  ) {
    self.store = store
    self.hostID = hostID
    self.fallbackKey = fallbackKey
    self.session = ReceiverSession(
      pairingKey: nil, hostID: hostID)
    self.sessionParameters = nil
  }

  public func pairingKey(for deviceID: String) -> Data? {
    if let store { return store.key(for: deviceID) }
    return fallbackKey
  }

  public var requiresStore: Bool { store != nil }

  public enum HelloOutcome: Sendable, Equatable {
    case reject(ControlMessage.HelloAck, disconnect: Bool)
    case pairingRequired(ControlMessage.HelloAck)
    /// Legacy path (no key store): the app's accept prompt decides.
    case needsAccept(ControlMessage.Hello)
    /// Verified proof under a stored key: pairing already had the user's
    /// consent, so no prompt.
    case authenticated(ControlMessage.Hello)
    case busy(ControlMessage.HelloAck)
  }

  public mutating func receiveHello(
    _ hello: ControlMessage.Hello, connectionGeneration: UInt64, busy: Bool, now: TimeInterval,
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
      sessionParameters = nil
      return .needsAccept(hello)
    }
    session.updatePairingKey(pairingKey(for: hello.deviceID), hostID: hostID)
    sessionParameters = nil
    let key = pairingKey(for: hello.deviceID)
    // Unpaired: invite to pair on this same connection, keep it open.
    guard let key else {
      pairingOnlyGeneration = connectionGeneration
      let ack = ControlMessage.HelloAck(
        accepted: false, reason: "Pair with this Mac", pairingRequired: true)
      return .pairingRequired(ack)
    }
    // Paired: require a valid proof with exactly 32-byte nonce.
    guard session.verifiesPairingProof(hello) else {
      pairingOnlyGeneration = nil
      _ = key
      return .reject(.init(accepted: false, reason: "Pair again"), disconnect: true)
    }
    // Authenticated and not busy: the caller calls `acceptHello` (no prompt)
    // to mint the host proof.
    pairingOnlyGeneration = nil
    return .authenticated(hello)
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
    pairingOnlyGeneration = nil
    if session.requiresPairingAuthentication {
      let deviceNonceData =
        (hello.nonce.flatMap { Data(base64Encoded: $0) }) ?? PairingCrypto.randomNonce()
      let hostNonceData = PairingCrypto.randomNonce()
      guard let key = pairingKey(for: hello.deviceID) else {
        sessionConnected = false
        return .init(accepted: false, reason: "Session could not be established")
      }
      let parameters: SessionParameters
      do {
        parameters = try SessionParameters(pairKey: key, ipadNonce: deviceNonceData, hostNonce: hostNonceData)
      } catch {
        sessionConnected = false
        return .init(accepted: false, reason: "Session could not be established")
      }
      sessionParameters = parameters
      return session.authenticatedHelloAck(
        deviceNonce: deviceNonceData, hostNonce: hostNonceData, accepted: true,
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
  public func allows(_ message: ControlMessage, connectionGeneration: UInt64) -> Bool {
    guard let pairingOnlyGeneration, pairingOnlyGeneration == connectionGeneration else {
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

  public mutating func connectionLost(_ generation: UInt64) {
    if pairingOnlyGeneration == generation {
      pairingOnlyGeneration = nil
    }
    // Full session loss is handled by the owner (session.disconnect).
    sessionParameters = nil
  }

  public mutating func newConnection(_ generation: UInt64) {
    // The owner calls this only after deciding the old connection may be
    // displaced. It clears all pairing-only state before installing the new
    // generation, so a recycled object identity cannot inherit it.
    if pairingOnlyGeneration != generation {
      pairingOnlyGeneration = nil
    }
  }

  public mutating func clearPairingOnly(_ generation: UInt64) {
    if pairingOnlyGeneration == generation {
      pairingOnlyGeneration = nil
    }
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
  public private(set) var knownHostID: String?
  public private(set) var sessionParameters: SessionParameters?
  public let sessionArm: DeviceSessionArm

  public init(
    store: PairingKeyStore? = nil, hostID: String? = nil, baseHello: ControlMessage.Hello? = nil
  ) {
    self.store = store
    self.hostID = hostID
    self.baseHello = baseHello
    self.sessionParameters = nil
    self.sessionArm = DeviceSessionArm()
  }

  public mutating func updateStore(store: PairingKeyStore?, hostID: String?) {
    self.store = store
    self.hostID = hostID
    knownHostID = hostID
  }

  public mutating func connectionLost() {
    pairingRequired = false
    lastDeviceNonce = nil
    sessionParameters = nil
    sessionArm.clear()
  }

  public func allows(_ message: ControlMessage) -> Bool {
    guard pairingRequired else { return true }
    switch message {
    case .helloAck, .pairResponse, .pairResult, .ping:
      return true
    case .hello, .geometry, .probe, .probeReply, .gesture, .frontApp, .pairRequest, .pairReveal:
      return false
    }
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
    sessionArm.prepare(pairKey: pairKey, deviceNonce: nonce, hostID: hostID)
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
      // A host that has not proved its key may suggest pairing, but cannot
      // overwrite trusted host metadata when a key is already held.
      return .pairingRequired(
        reason: ack.reason ?? "Pair with this Mac", hostInfo: keyHeld ? nil : ack.host)
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
        if let hostNonceString = ack.nonce, let hostNonce = Data(base64Encoded: hostNonceString),
          let key = storedKey(), let deviceNonce = lastDeviceNonce
        {
          let parameters: SessionParameters
          do {
            parameters = try SessionParameters(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce)
          } catch { return .invalidProof }
          sessionParameters = parameters
        } else {
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

  /// Builds the authenticated session without changing pairing state. The
  /// transport dispatcher calls this synchronously while it still owns the
  /// plaintext receive buffer, before it examines bytes following helloAck.
  public func sessionCipher(for ack: ControlMessage.HelloAck) -> SessionCipher? {
    if let cipher = sessionArm.make(ack) { return cipher }
    guard ack.accepted, let key = storedKey(), let deviceNonce = lastDeviceNonce,
      let hostNonceString = ack.nonce, let hostNonce = Data(base64Encoded: hostNonceString),
      let proof = ack.proof,
      PairingCrypto.verifyHostProof(
        base64Proof: proof, pairKey: key, hostID: hostID ?? "",
        base64DeviceNonce: PairingCrypto.base64(deviceNonce), base64HostNonce: hostNonceString)
    else { return nil }
    return try? SessionCipher(pairKey: key, ipadNonce: deviceNonce, hostNonce: hostNonce, role: .device)
  }

  private func makeSession() -> SenderSession? {
    guard let store, let hostID else { return nil }
    let key = store.key(for: hostID)
    return SenderSession(pairKey: key, hostID: hostID, deviceID: baseHello?.deviceID)
  }
}
