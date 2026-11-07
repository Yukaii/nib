import CryptoKit
import Foundation

/// The two endpoints use the same byte order for the numeric-comparison
/// transcript: length-prefixed deviceID, length-prefixed hostID, device public
/// key, host public key, device nonce, host nonce. Length prefixes are 2-byte
/// big-endian. Keys and nonces are fixed 32 bytes.
public struct PairingTranscript: Sendable, Equatable {
  public let deviceID: String
  public let hostID: String
  public let devicePublicKey: Data
  public let hostPublicKey: Data
  public let deviceNonce: Data
  public let hostNonce: Data

  public init(
    deviceID: String, hostID: String, devicePublicKey: Data, hostPublicKey: Data, deviceNonce: Data,
    hostNonce: Data
  ) throws {
    guard devicePublicKey.count == 32, hostPublicKey.count == 32,
      deviceNonce.count == 32, hostNonce.count == 32
    else { throw PairingCrypto.Error.invalidLength }
    self.deviceID = deviceID
    self.hostID = hostID
    self.devicePublicKey = devicePublicKey
    self.hostPublicKey = hostPublicKey
    self.deviceNonce = deviceNonce
    self.hostNonce = hostNonce
  }

  public var bytes: Data {
    PairingCrypto.lengthPrefixed(deviceID) + PairingCrypto.lengthPrefixed(hostID) + devicePublicKey
      + hostPublicKey + deviceNonce + hostNonce
  }

  public var hash: Data { Data(SHA256.hash(data: bytes)) }
}

public struct PairingKeyPair: Sendable, Equatable {
  public let privateKey: Data
  public let publicKey: Data

  public init(privateKey: Data) throws {
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    self.privateKey = privateKey
    publicKey = key.publicKey.rawRepresentation
  }

  public static func random() -> Self {
    let key = Curve25519.KeyAgreement.PrivateKey()
    return try! Self(privateKey: key.rawRepresentation)
  }
}

public enum PairingCrypto {
  public enum Error: Swift.Error, Equatable {
    case invalidBase64
    case invalidLength
    case invalidKey
  }

  // Prefix-free labels: none is a prefix of another. The spec states this so
  // HMAC/SHA256 domains never collide.
  private static let codeLabel = Data("nib-pair-code".utf8)
  private static let keyInfo = Data("nib-pair-key".utf8)
  private static let helloLabel = Data("nib-hello".utf8)
  private static let helloAckLabel = Data("nib-ack".utf8)
  private static let commitLabel = Data("nib-commit".utf8)

  public static func areLabelsPrefixFree() -> Bool {
    let labels = [codeLabel, keyInfo, helloLabel, helloAckLabel, commitLabel]
    for i in labels.indices {
      for j in labels.indices where i != j {
        let a = labels[i]
        let b = labels[j]
        if b.count >= a.count, b.prefix(a.count) == a { return false }
      }
    }
    return true
  }

  public static func lengthPrefixed(_ string: String) -> Data {
    let bytes = Data(string.utf8)
    precondition(bytes.count <= Int(UInt16.max))
    return u16BE(bytes.count) + bytes
  }

  static func u16BE(_ value: Int) -> Data {
    Data([UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
  }

  public static func base64(_ data: Data) -> String { data.base64EncodedString() }

  public static func randomNonce() -> Data {
    Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
  }

  public static func data(base64: String) throws -> Data {
    guard let data = Data(base64Encoded: base64) else { throw Error.invalidBase64 }
    return data
  }

  /// Commitment sent in `pairRequest` so the host must lock its nonce first:
  /// `SHA256("nib-commit" ‖ len(deviceID) ‖ deviceID ‖ devicePublicKey ‖ deviceNonce)`.
  /// `len` is a 2-byte big-endian length. The deviceID binds the commitment to
  /// one iPad so a relay cannot relabel it.
  public static func commitment(deviceID: String, publicKey: Data, nonce: Data) -> Data {
    Data(SHA256.hash(data: commitLabel + lengthPrefixed(deviceID) + publicKey + nonce))
  }

  public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
  }

  public static func verifyCommitment(
    _ commitment: Data, deviceID: String, publicKey: Data, nonce: Data
  ) -> Bool {
    guard publicKey.count == 32, nonce.count == 32 else { return false }
    return constantTimeEqual(
      commitment, self.commitment(deviceID: deviceID, publicKey: publicKey, nonce: nonce))
  }

  public static func numericCode(for transcript: PairingTranscript) -> String {
    let digest = SHA256.hash(data: codeLabel + transcript.bytes)
    let bytes = Array(digest)
    let value =
      (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8)
      | UInt32(bytes[3])
    return String(format: "%06u", value % 1_000_000)
  }

  public static func pairKey(
    privateKey: Data, peerPublicKey: Data, transcript: PairingTranscript
  ) throws -> Data {
    guard privateKey.count == 32, peerPublicKey.count == 32 else { throw Error.invalidLength }
    do {
      let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
      let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
      let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
      return Data(
        shared.hkdfDerivedSymmetricKey(
          using: SHA256.self, salt: transcript.hash, sharedInfo: keyInfo, outputByteCount: 32
        )
        .withUnsafeBytes { Data($0) })
    } catch { throw Error.invalidKey }
  }

  /// Device proof in `hello`: binds the device nonce (exactly 32 bytes).
  public static func helloProof(pairKey: Data, identifier: String, nonce: Data) -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: helloLabel + Data(identifier.utf8) + nonce, using: SymmetricKey(data: pairKey)))
  }

  public static func verifyHelloProof(
    _ proof: Data, pairKey: Data, identifier: String, nonce: Data
  ) -> Bool {
    guard nonce.count == 32, proof.count == 32 else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof, authenticating: helloLabel + Data(identifier.utf8) + nonce,
      using: SymmetricKey(data: pairKey))
  }

  public static func verifyHelloProof(
    base64Proof: String, pairKey: Data, identifier: String, base64Nonce: String
  ) -> Bool {
    guard let proof = Data(base64Encoded: base64Proof), let nonce = Data(base64Encoded: base64Nonce)
    else { return false }
    return verifyHelloProof(proof, pairKey: pairKey, identifier: identifier, nonce: nonce)
  }

  /// Host proof in `helloAck`: distinct label and binds both nonces (each
  /// exactly 32 bytes) so a recorded ack cannot be replayed against a fresh
  /// device nonce.
  public static func hostProof(
    pairKey: Data, hostID: String, deviceNonce: Data, hostNonce: Data
  ) -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: helloAckLabel + Data(hostID.utf8) + deviceNonce + hostNonce,
        using: SymmetricKey(data: pairKey)))
  }

  public static func verifyHostProof(
    _ proof: Data, pairKey: Data, hostID: String, deviceNonce: Data, hostNonce: Data
  ) -> Bool {
    guard deviceNonce.count == 32, hostNonce.count == 32, proof.count == 32 else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof,
      authenticating: helloAckLabel + Data(hostID.utf8) + deviceNonce + hostNonce,
      using: SymmetricKey(data: pairKey))
  }

  public static func verifyHostProof(
    base64Proof: String, pairKey: Data, hostID: String, base64DeviceNonce: String,
    base64HostNonce: String
  ) -> Bool {
    guard let proof = Data(base64Encoded: base64Proof),
      let deviceNonce = Data(base64Encoded: base64DeviceNonce),
      let hostNonce = Data(base64Encoded: base64HostNonce)
    else { return false }
    return verifyHostProof(
      proof, pairKey: pairKey, hostID: hostID, deviceNonce: deviceNonce, hostNonce: hostNonce)
  }
}

public protocol PairingKeyStore: AnyObject, Sendable {
  func key(for peerID: String) -> Data?
  func save(_ key: Data, for peerID: String)
  func removeKey(for peerID: String)
}

/// Deterministic store used by the core tests. Apps provide a Keychain-backed
/// implementation at their boundary.
public final class InMemoryPairingKeyStore: PairingKeyStore, @unchecked Sendable {
  private var values: [String: Data] = [:]
  private let lock = NSLock()

  public init() {}

  public func key(for peerID: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[peerID]
  }

  public func save(_ key: Data, for peerID: String) {
    lock.lock()
    defer { lock.unlock() }
    values[peerID] = key
  }

  public func removeKey(for peerID: String) {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: peerID)
  }
}

public enum PairingRole: Sendable, Equatable { case device, host }

public enum PairingPhase: Sendable, Equatable {
  case idle
  case waitingForResponse
  case waitingForReveal
  case showingCode(String)
  case waitingForPeer
  case paired
  case cancelled
  case timedOut
  case failed
}

public enum PairingEvent: Sendable, Equatable {
  case send(ControlMessage)
  case showCode(String)
  case paired(peerID: String)
  case cancelled
  case timedOut
  case failed(String)
}

/// App-facing pairing lifecycle. The transport calls into the state machine
/// and forwards these to the UI.
public enum PairingTransportEvent: Sendable, Equatable {
  case showCode(String, peerName: String)
  case paired(peerID: String)
  case cancelled
  case timedOut
  case failed(String)
}

public enum PairingTransportPolicy {
  /// Pairing must complete while the user is looking at both screens.
  /// Expiry stores nothing.
  public static let timeoutSeconds: UInt64 = 60
  /// An invited connection that has not started pairing cannot squat forever.
  public static let pairingIdleSeconds: TimeInterval = 10
}

/// Host-side attempt limiting: after 3 failed or cancelled pairings within 5
/// minutes, new `pairRequest`s are refused for 60 seconds. The clock is
/// injected (`now` in seconds) so tests are deterministic.
public struct PairingAttemptLimiter: Sendable, Equatable {
  public static let maxFailures = 3
  public static let windowSeconds: TimeInterval = 300
  public static let blockSeconds: TimeInterval = 60

  private var failures: [TimeInterval] = []

  public init() {}

  public mutating func recordFailure(at now: TimeInterval) {
    failures.append(now)
    prune(at: now)
  }

  public func canAttempt(at now: TimeInterval) -> Bool {
    let recent = failures.filter { now - $0 < Self.windowSeconds && now - $0 >= 0 }
    guard recent.count >= Self.maxFailures else { return true }
    guard let last = recent.max() else { return true }
    return now - last >= Self.blockSeconds
  }

  public static func refusalReason() -> String {
    "Too many pairing attempts. Try again in a minute."
  }

  private mutating func prune(at now: TimeInterval) {
    failures = failures.filter { now - $0 < Self.windowSeconds && now - $0 >= 0 }
  }
}

/// Pure, transport-independent pairing flow with commit-reveal. The device
/// commits to its nonce before the host reveals its own, so neither side can
/// grind nonces to force a matching code. No key is persisted until both
/// endpoints have confirmed the same numeric code.
public struct PairingStateMachine: Sendable {
  public let role: PairingRole
  public let id: String
  public let name: String
  public private(set) var phase: PairingPhase = .idle

  private let keyPair: PairingKeyPair
  private let store: PairingKeyStore
  private var localNonce: Data?
  private var peerPublicKey: Data?
  private var peerNonce: Data?
  private var peerID: String?
  private var peerName: String?
  private var receivedCommitment: Data?
  private var pendingKey: Data?
  private var localConfirmed = false
  private var peerConfirmed = false

  public init(
    role: PairingRole, id: String, name: String, keyPair: PairingKeyPair = .random(),
    store: PairingKeyStore
  ) {
    self.role = role
    self.id = id
    self.name = name
    self.keyPair = keyPair
    self.store = store
  }

  public var peerDisplayName: String? { peerName }

  public mutating func begin(nonce: Data? = nil) throws -> PairingEvent? {
    guard phase == .idle else { return nil }
    let nonce = nonce ?? PairingCrypto.randomNonce()
    guard nonce.count == 32 else { throw PairingCrypto.Error.invalidLength }
    guard role == .device else { return nil }
    localNonce = nonce
    let commitment = PairingCrypto.commitment(
      deviceID: id, publicKey: keyPair.publicKey, nonce: nonce)
    phase = .waitingForResponse
    return .send(
      .pairRequest(
        .init(
          deviceID: id, deviceName: name, publicKey: PairingCrypto.base64(keyPair.publicKey),
          commitment: PairingCrypto.base64(commitment))))
  }

  public mutating func receive(_ message: ControlMessage) -> [PairingEvent] {
    // A stray message for the other role never aborts pairing.
    switch message {
    case .pairRequest(let request) where role == .host:
      return receive(request)
    case .pairResponse(let response) where role == .device:
      return receive(response)
    case .pairReveal(let reveal) where role == .host:
      return receive(reveal)
    case .pairResult(let result):
      return receive(result)
    default:
      return []
    }
  }

  private mutating func receive(_ request: ControlMessage.PairRequest) -> [PairingEvent] {
    // A second pairRequest mid-flow is ignored, not a failure: the machine
    // belongs to the connection that started it (the transport enforces the
    // binding) and a stray request must not abort the visible code.
    guard phase == .idle else { return [] }
    guard let deviceKey = try? PairingCrypto.data(base64: request.publicKey),
      let commitment = try? PairingCrypto.data(base64: request.commitment),
      deviceKey.count == 32, commitment.count == 32
    else { return fail("The pairing request is invalid.") }
    let hostNonce = PairingCrypto.randomNonce()
    localNonce = hostNonce
    peerPublicKey = deviceKey
    peerID = request.deviceID
    peerName = request.deviceName
    receivedCommitment = commitment
    phase = .waitingForReveal
    let response = ControlMessage.PairResponse(
      hostID: id, hostName: name, publicKey: PairingCrypto.base64(keyPair.publicKey),
      nonce: PairingCrypto.base64(hostNonce))
    return [.send(.pairResponse(response))]
  }

  private mutating func receive(_ response: ControlMessage.PairResponse) -> [PairingEvent] {
    guard phase == .waitingForResponse, let deviceNonce = localNonce else {
      return fail("Unexpected pairing response.")
    }
    guard let hostKey = try? PairingCrypto.data(base64: response.publicKey),
      let hostNonce = try? PairingCrypto.data(base64: response.nonce), hostKey.count == 32,
      hostNonce.count == 32,
      let transcript = try? PairingTranscript(
        deviceID: id, hostID: response.hostID, devicePublicKey: keyPair.publicKey,
        hostPublicKey: hostKey,
        deviceNonce: deviceNonce, hostNonce: hostNonce),
      let key = try? PairingCrypto.pairKey(
        privateKey: keyPair.privateKey, peerPublicKey: hostKey, transcript: transcript)
    else { return fail("The pairing response is invalid.") }
    peerPublicKey = hostKey
    peerNonce = hostNonce
    peerID = response.hostID
    peerName = response.hostName
    pendingKey = key
    let code = PairingCrypto.numericCode(for: transcript)
    phase = .showingCode(code)
    return [
      .send(.pairReveal(.init(nonce: PairingCrypto.base64(deviceNonce)))),
      .showCode(code),
    ]
  }

  private mutating func receive(_ reveal: ControlMessage.PairReveal) -> [PairingEvent] {
    guard phase == .waitingForReveal else { return fail("Unexpected pairing reveal.") }
    guard let deviceKey = peerPublicKey,
      let commitment = receivedCommitment,
      let hostNonce = localNonce,
      let deviceID = peerID,
      let deviceNonce = try? PairingCrypto.data(base64: reveal.nonce),
      deviceNonce.count == 32
    else { return fail("The pairing reveal is invalid.") }
    guard
      PairingCrypto.verifyCommitment(
        commitment, deviceID: deviceID, publicKey: deviceKey, nonce: deviceNonce)
    else {
      return fail("The pairing code did not match. Try pairing again.")
    }
    guard
      let transcript = try? PairingTranscript(
        deviceID: deviceID, hostID: id, devicePublicKey: deviceKey,
        hostPublicKey: keyPair.publicKey,
        deviceNonce: deviceNonce, hostNonce: hostNonce),
      let key = try? PairingCrypto.pairKey(
        privateKey: keyPair.privateKey, peerPublicKey: deviceKey, transcript: transcript)
    else { return fail("The pairing reveal is invalid.") }
    peerNonce = deviceNonce
    pendingKey = key
    let code = PairingCrypto.numericCode(for: transcript)
    phase = .showingCode(code)
    return [.showCode(code)]
  }

  private mutating func receive(_ result: ControlMessage.PairResult) -> [PairingEvent] {
    // Terminal phases never re-fire: an early, duplicate or late result is
    // ignored once pairing has settled.
    if isTerminal || phase == .idle { return [] }
    // A rejection aborts from any in-progress phase; an acceptance only
    // counts once both sides can see the code.
    if !result.accepted {
      clearPending()
      phase = .cancelled
      return [.cancelled]
    }
    guard isCodeVisible || phase == .waitingForPeer else { return [] }
    peerConfirmed = true
    return completeIfReady()
  }

  private var isCodeVisible: Bool {
    if case .showingCode = phase { return true }
    return false
  }

  public mutating func confirm() -> [PairingEvent] {
    guard case .showingCode = phase, pendingKey != nil else { return [] }
    localConfirmed = true
    phase = .waitingForPeer
    return [.send(.pairResult(.init(accepted: true)))] + completeIfReady()
  }

  public mutating func cancel() -> PairingEvent {
    guard phase != .paired, phase != .idle else { return .cancelled }
    clearPending()
    phase = .cancelled
    return .send(.pairResult(.init(accepted: false, reason: "Pairing cancelled.")))
  }

  public mutating func timeout() -> PairingEvent {
    guard phase != .paired, phase != .idle else { return .timedOut }
    clearPending()
    phase = .timedOut
    return .timedOut
  }

  public var isTerminal: Bool {
    switch phase {
    case .paired, .cancelled, .timedOut, .failed: return true
    default: return false
    }
  }

  private mutating func completeIfReady() -> [PairingEvent] {
    guard localConfirmed, peerConfirmed, let key = pendingKey, let peerID else { return [] }
    store.save(key, for: peerID)
    clearPending()
    phase = .paired
    return [.paired(peerID: peerID)]
  }

  private mutating func clearPending() {
    localNonce = nil
    peerPublicKey = nil
    peerNonce = nil
    peerID = nil
    peerName = nil
    receivedCommitment = nil
    pendingKey = nil
    localConfirmed = false
    peerConfirmed = false
  }

  private mutating func fail(_ reason: String) -> [PairingEvent] {
    clearPending()
    phase = .failed
    return [.failed(reason)]
  }
}

/// Pure device-side session for verifying the host proof in `helloAck`.
/// No network or storage access; the transport supplies the stored key.
public struct SenderSession: Sendable, Equatable {
  public var pairKey: Data?
  public var hostID: String?
  public var deviceID: String?

  public init(pairKey: Data? = nil, hostID: String? = nil, deviceID: String? = nil) {
    self.pairKey = pairKey
    self.hostID = hostID
    self.deviceID = deviceID
  }

  public var requiresAuthentication: Bool { pairKey != nil }

  public func deviceHello(nonce: Data) -> (nonce: String, proof: String)? {
    guard let pairKey, let deviceID else { return nil }
    return (
      PairingCrypto.base64(nonce),
      PairingCrypto.base64(PairingCrypto.helloProof(pairKey: pairKey, identifier: deviceID, nonce: nonce))
    )
  }

  /// Verifies the host proof. With no stored key (unpaired, opt-in off) any
  /// ack is accepted to preserve today's behaviour; with a key, a missing or
  /// invalid proof fails.
  public func verifiesHelloAck(_ ack: ControlMessage.HelloAck, deviceNonce: Data) -> Bool {
    guard let pairKey, let hostID else { return true }
    guard let hostNonceString = ack.nonce, let proofString = ack.proof,
      let hostNonce = Data(base64Encoded: hostNonceString),
      let proof = Data(base64Encoded: proofString)
    else { return false }
    return PairingCrypto.verifyHostProof(
      proof, pairKey: pairKey, hostID: hostID, deviceNonce: deviceNonce, hostNonce: hostNonce)
  }
}
