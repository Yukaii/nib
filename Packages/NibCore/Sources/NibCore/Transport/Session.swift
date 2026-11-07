import CryptoKit
import Foundation

/// The direction labels are part of the wire protocol. They ensure that a
/// packet sent in one direction cannot be opened by the peer's send key.
public enum SessionDirection: Sendable, Equatable {
  case ipadToHost
  case hostToIpad
}

public enum SessionCryptoError: Error, Equatable {
  case invalidKeyMaterial
  case invalidNonceMaterial
  case invalidControlFrame
  case invalidSampleFrame
  case counterMismatch(expected: UInt64, actual: UInt64)
  case sequenceWrap
  case authenticationFailed
}

public struct SessionParameters: Sendable, Equatable {
  public let pairKey: Data
  public let ipadNonce: Data
  public let hostNonce: Data

  public init(pairKey: Data, ipadNonce: Data, hostNonce: Data) throws {
    guard pairKey.count == 32, ipadNonce.count == 32, hostNonce.count == 32 else {
      throw SessionCryptoError.invalidKeyMaterial
    }
    self.pairKey = pairKey
    self.ipadNonce = ipadNonce
    self.hostNonce = hostNonce
  }
}

/// HKDF output and the per-session epoch derived from the two authenticated
/// hello nonces. The epoch is eight bytes and is placed before a sample's
/// little-endian sequence in its 12-byte ChaCha20-Poly1305 nonce.
public struct SessionKeyMaterial: Sendable, Equatable {
  public let ipadToHost: Data
  public let hostToIpad: Data
  public let epoch: Data

  public init(pairKey: Data, ipadNonce: Data, hostNonce: Data) throws {
    guard pairKey.count == 32, ipadNonce.count == 32, hostNonce.count == 32 else {
      throw SessionCryptoError.invalidKeyMaterial
    }
    let salt = ipadNonce + hostNonce
    func derive(_ info: String, count: Int) -> Data {
      let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: pairKey), salt: salt,
        info: Data(info.utf8), outputByteCount: count)
      return key.withUnsafeBytes { Data($0) }
    }
    ipadToHost = derive("nib-session ipad→host", count: 32)
    hostToIpad = derive("nib-session host→ipad", count: 32)
    epoch = derive("nib-session epoch", count: 8)
  }

  public static func derive(pairKey: Data, ipadNonce: Data, hostNonce: Data) throws -> Self {
    try Self(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce)
  }
}

/// Stateless sample/control primitive plus a checked receive counter. A new
/// session is required before sequence 0 is used again after UInt32.max.
public struct SessionSealer: Sendable {
  public let direction: SessionDirection
  public let key: Data
  public let epoch: Data
  private var nextSendCounter: UInt64 = 0
  private var nextReceiveCounter: UInt64 = 0

  public init(key: Data, epoch: Data, direction: SessionDirection) throws {
    guard key.count == 32, epoch.count == 8 else { throw SessionCryptoError.invalidKeyMaterial }
    self.key = key
    self.epoch = epoch
    self.direction = direction
  }

  public mutating func sealControl(_ plaintext: Data) throws -> Data {
    let counter = nextSendCounter
    nextSendCounter &+= 1
    return try sealControl(plaintext, counter: counter)
  }

  public func sealControl(_ plaintext: Data, counter: UInt64) throws -> Data {
    let nonce = try controlNonce(counter)
    let box: ChaChaPoly.SealedBox
    do {
      box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
    } catch { throw SessionCryptoError.authenticationFailed }
    return littleEndian(counter) + box.ciphertext + box.tag
  }

  public mutating func openControl(_ body: Data) throws -> Data {
    guard body.count >= 8 + 16 else { throw SessionCryptoError.invalidControlFrame }
    let counter = readLE64(body, offset: 0)
    guard counter == nextReceiveCounter else {
      throw SessionCryptoError.counterMismatch(expected: nextReceiveCounter, actual: counter)
    }
    let plaintext = try openControl(body, counter: counter)
    nextReceiveCounter &+= 1
    return plaintext
  }

  public func openControl(_ body: Data, counter: UInt64) throws -> Data {
    guard body.count >= 8 + 16, readLE64(body, offset: 0) == counter else {
      throw SessionCryptoError.invalidControlFrame
    }
    let nonce = try controlNonce(counter)
    let ciphertext = body.dropFirst(8).dropLast(16)
    let tag = body.suffix(16)
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
      return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    } catch { throw SessionCryptoError.authenticationFailed }
  }

  public func sealSample(_ plaintext: Data, sequence: UInt32) throws -> Data {
    guard plaintext.count == 40 else { throw SessionCryptoError.invalidSampleFrame }
    // Sequence wrap is a rekey boundary. Reusing the same epoch would reuse a
    // nonce, so callers must complete a fresh authenticated hello first.
    guard sequence != .max else { throw SessionCryptoError.sequenceWrap }
    let nonce = try sampleNonce(sequence)
    do {
      let box = try ChaChaPoly.seal(
        plaintext, using: SymmetricKey(data: key), nonce: nonce)
      return littleEndian(sequence) + box.ciphertext + box.tag
    } catch { throw SessionCryptoError.authenticationFailed }
  }

  public func openSample(_ packet: Data) throws -> (sequence: UInt32, plaintext: Data) {
    guard packet.count == 4 + 40 + 16 else { throw SessionCryptoError.invalidSampleFrame }
    let sequence = readLE32(packet, offset: 0)
    guard sequence != .max else { throw SessionCryptoError.sequenceWrap }
    let nonce = try sampleNonce(sequence)
    let ciphertext = packet.dropFirst(4).dropLast(16)
    let tag = packet.suffix(16)
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
      return (sequence, try ChaChaPoly.open(box, using: SymmetricKey(data: key)))
    } catch { throw SessionCryptoError.authenticationFailed }
  }

  public func controlNonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
    try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + littleEndian(counter))
  }

  public func sampleNonce(_ sequence: UInt32) throws -> ChaChaPoly.Nonce {
    try ChaChaPoly.Nonce(data: epoch + littleEndian(sequence))
  }

  private func littleEndian(_ value: UInt64) -> Data {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private func littleEndian(_ value: UInt32) -> Data {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private func readLE64(_ data: Data, offset: Int) -> UInt64 {
    data[offset..<offset + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (UInt64($1.offset) * 8) }
  }

  private func readLE32(_ data: Data, offset: Int) -> UInt32 {
    data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (UInt32($1.offset) * 8) }
  }
}

/// A directional pair used by a transport. It intentionally exposes no
/// plaintext or key logging hooks.
public struct SessionCipher: Sendable {
  public let role: PairingRole
  private var outbound: SessionSealer
  private var inbound: SessionSealer

  public init(pairKey: Data, ipadNonce: Data, hostNonce: Data, role: PairingRole) throws {
    let material = try SessionKeyMaterial(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce)
    self.role = role
    switch role {
    case .device:
      outbound = try SessionSealer(key: material.ipadToHost, epoch: material.epoch, direction: .ipadToHost)
      inbound = try SessionSealer(key: material.hostToIpad, epoch: material.epoch, direction: .hostToIpad)
    case .host:
      outbound = try SessionSealer(key: material.hostToIpad, epoch: material.epoch, direction: .hostToIpad)
      inbound = try SessionSealer(key: material.ipadToHost, epoch: material.epoch, direction: .ipadToHost)
    }
  }

  public mutating func sealControl(_ plaintext: Data) throws -> Data { try outbound.sealControl(plaintext) }
  public mutating func openControl(_ body: Data) throws -> Data { try inbound.openControl(body) }
  public func sealSample(_ plaintext: Data, sequence: UInt32) throws -> Data {
    try outbound.sealSample(plaintext, sequence: sequence)
  }
  public func openSample(_ packet: Data) throws -> (sequence: UInt32, plaintext: Data) {
    try inbound.openSample(packet)
  }
}
