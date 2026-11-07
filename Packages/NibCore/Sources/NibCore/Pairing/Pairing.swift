import CryptoKit
import Foundation

/// The two endpoints use the same byte order for the numeric-comparison
/// transcript: device public key, host public key, device nonce, host nonce.
public struct PairingTranscript: Sendable, Equatable {
  public let devicePublicKey: Data
  public let hostPublicKey: Data
  public let deviceNonce: Data
  public let hostNonce: Data

  public init(devicePublicKey: Data, hostPublicKey: Data, deviceNonce: Data, hostNonce: Data) throws {
    guard devicePublicKey.count == 32, hostPublicKey.count == 32,
      deviceNonce.count == 32, hostNonce.count == 32
    else { throw PairingCrypto.Error.invalidLength }
    self.devicePublicKey = devicePublicKey
    self.hostPublicKey = hostPublicKey
    self.deviceNonce = deviceNonce
    self.hostNonce = hostNonce
  }

  public var bytes: Data {
    devicePublicKey + hostPublicKey + deviceNonce + hostNonce
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

  private static let pairLabel = Data("nib-pair".utf8)
  private static let keyInfo = Data("nib-pair-key".utf8)
  private static let helloLabel = Data("nib-hello".utf8)

  public static func base64(_ data: Data) -> String { data.base64EncodedString() }

  public static func randomNonce() -> Data {
    Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
  }

  public static func data(base64: String) throws -> Data {
    guard let data = Data(base64Encoded: base64) else { throw Error.invalidBase64 }
    return data
  }

  public static func numericCode(for transcript: PairingTranscript) -> String {
    let digest = SHA256.hash(data: pairLabel + transcript.bytes)
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

  public static func helloProof(pairKey: Data, identifier: String, nonce: Data) -> Data {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: helloLabel + Data(identifier.utf8) + nonce, using: SymmetricKey(data: pairKey)))
  }

  public static func verifyHelloProof(
    _ proof: Data, pairKey: Data, identifier: String, nonce: Data
  ) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(
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
  case showingCode(String)
  case waitingForPeer
  case paired
  case cancelled
  case timedOut
}

public enum PairingEvent: Sendable, Equatable {
  case send(ControlMessage)
  case showCode(String)
  case paired(peerID: String)
  case cancelled
  case timedOut
  case failed(String)
}

/// Pure, transport-independent pairing flow. No key is persisted until both
/// endpoints have confirmed the same numeric code.
public struct PairingStateMachine: Sendable {
  public let role: PairingRole
  public let id: String
  public let name: String
  public private(set) var phase: PairingPhase = .idle

  private let keyPair: PairingKeyPair
  private let store: PairingKeyStore
  private var nonce: Data?
  private var peerID: String?
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

  public mutating func begin(nonce: Data? = nil) throws -> PairingEvent? {
    guard phase == .idle else { return nil }
    let nonce = nonce ?? PairingCrypto.randomNonce()
    guard nonce.count == 32 else { throw PairingCrypto.Error.invalidLength }
    self.nonce = nonce
    guard role == .device else { return nil }
    phase = .waitingForResponse
    return .send(
      .pairRequest(
        .init(
          deviceID: id, deviceName: name, publicKey: PairingCrypto.base64(keyPair.publicKey),
          nonce: PairingCrypto.base64(nonce))))
  }

  public mutating func receive(_ message: ControlMessage) -> [PairingEvent] {
    switch message {
    case .pairRequest(let request) where role == .host:
      return receive(request)
    case .pairResponse(let response) where role == .device:
      return receive(response)
    case .pairResult(let result):
      return receive(result)
    default:
      return []
    }
  }

  private mutating func receive(_ request: ControlMessage.PairRequest) -> [PairingEvent] {
    guard phase == .idle else { return [.failed("Pairing is already in progress.")] }
    guard let deviceKey = try? PairingCrypto.data(base64: request.publicKey),
      let deviceNonce = try? PairingCrypto.data(base64: request.nonce), deviceKey.count == 32,
      deviceNonce.count == 32
    else { return fail("The pairing request is invalid.") }
    let hostNonce = PairingCrypto.randomNonce()
    guard
      let transcript = try? PairingTranscript(
        devicePublicKey: deviceKey, hostPublicKey: keyPair.publicKey,
        deviceNonce: deviceNonce, hostNonce: hostNonce),
      let key = try? PairingCrypto.pairKey(
        privateKey: keyPair.privateKey, peerPublicKey: deviceKey, transcript: transcript)
    else { return fail("The pairing request is invalid.") }
    nonce = hostNonce
    peerID = request.deviceID
    pendingKey = key
    let code = PairingCrypto.numericCode(for: transcript)
    phase = .showingCode(code)
    return [
      .send(
        .pairResponse(
          .init(
            hostID: id, hostName: name, publicKey: PairingCrypto.base64(keyPair.publicKey),
            nonce: PairingCrypto.base64(hostNonce)))),
      .showCode(code),
    ]
  }

  private mutating func receive(_ response: ControlMessage.PairResponse) -> [PairingEvent] {
    guard phase == .waitingForResponse, let nonce else { return fail("Unexpected pairing response.") }
    guard let hostKey = try? PairingCrypto.data(base64: response.publicKey),
      let hostNonce = try? PairingCrypto.data(base64: response.nonce), hostKey.count == 32,
      hostNonce.count == 32,
      let transcript = try? PairingTranscript(
        devicePublicKey: keyPair.publicKey, hostPublicKey: hostKey,
        deviceNonce: nonce, hostNonce: hostNonce),
      let key = try? PairingCrypto.pairKey(
        privateKey: keyPair.privateKey, peerPublicKey: hostKey, transcript: transcript)
    else { return fail("The pairing response is invalid.") }
    peerID = response.hostID
    pendingKey = key
    let code = PairingCrypto.numericCode(for: transcript)
    phase = .showingCode(code)
    return [.showCode(code)]
  }

  private mutating func receive(_ result: ControlMessage.PairResult) -> [PairingEvent] {
    guard isCodeVisible || phase == .waitingForPeer else {
      return []
    }
    guard result.accepted else {
      clearPending()
      phase = .cancelled
      return [.cancelled]
    }
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
    guard phase != .paired else { return .cancelled }
    clearPending()
    phase = .cancelled
    return .send(.pairResult(.init(accepted: false, reason: "Pairing cancelled.")))
  }

  public mutating func timeout() -> PairingEvent {
    guard phase != .paired else { return .timedOut }
    clearPending()
    phase = .timedOut
    return .timedOut
  }

  private mutating func completeIfReady() -> [PairingEvent] {
    guard localConfirmed, peerConfirmed, let key = pendingKey, let peerID else { return [] }
    store.save(key, for: peerID)
    clearPending()
    phase = .paired
    return [.paired(peerID: peerID)]
  }

  private mutating func clearPending() {
    nonce = nil
    peerID = nil
    pendingKey = nil
    localConfirmed = false
    peerConfirmed = false
  }

  private func fail(_ reason: String) -> [PairingEvent] {
    [.failed(reason)]
  }
}
