import CryptoKit
import Foundation

public enum SessionDirection: Sendable, Equatable { case ipadToHost, hostToIpad }

public enum SessionCryptoError: Error, Equatable {
  case invalidKeyMaterial, invalidNonceMaterial, invalidControlFrame, invalidSampleFrame
  case counterMismatch(expected: UInt64, actual: UInt64)
  case sequenceWrap, sequenceReplay
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
    self.pairKey = Data(pairKey)
    self.ipadNonce = Data(ipadNonce)
    self.hostNonce = Data(hostNonce)
  }
}

public struct SessionKeyMaterial: Sendable, Equatable {
  public let ipadToHostControl: Data
  public let hostToIpadControl: Data
  public let ipadToHostSample: Data
  public let hostToIpadSample: Data
  public let epoch: Data

  public init(pairKey: Data, ipadNonce: Data, hostNonce: Data) throws {
    guard pairKey.count == 32, ipadNonce.count == 32, hostNonce.count == 32 else {
      throw SessionCryptoError.invalidKeyMaterial
    }
    let salt = ipadNonce + hostNonce
    func derive(_ info: String, _ count: Int) -> Data {
      let key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: pairKey), salt: salt, info: Data(info.utf8),
        outputByteCount: count)
      return key.withUnsafeBytes { Data($0) }
    }
    ipadToHostControl = derive("nib-session control ipad→host", 32)
    hostToIpadControl = derive("nib-session control host→ipad", 32)
    ipadToHostSample = derive("nib-session sample ipad→host", 32)
    hostToIpadSample = derive("nib-session sample host→ipad", 32)
    epoch = derive("nib-session epoch", 8)
  }
  public static func derive(pairKey: Data, ipadNonce: Data, hostNonce: Data) throws -> Self {
    try Self(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce)
  }
}

/// Thread-safe directional primitive. Keys and epoch are immutable; counters and
/// sample replay state are protected independently so seal/open can run off-main.
public final class SessionSealer: @unchecked Sendable {
  public let direction: SessionDirection
  let key: Data
  let epoch: Data
  private let counterLock = NSLock()
  private var nextSendCounter: UInt64 = 0
  private var nextReceiveCounter: UInt64 = 0
  private let sampleLock = NSLock()
  private var lastSample: (sequence: UInt32, digest: Data)?
  private var sampleWrapped = false

  public init(key: Data, epoch: Data, direction: SessionDirection) throws {
    guard key.count == 32, epoch.count == 8 else { throw SessionCryptoError.invalidKeyMaterial }
    self.key = Data(key)
    self.epoch = Data(epoch)
    self.direction = direction
  }

  public func sealControl(_ plaintext: Data) throws -> Data {
    counterLock.lock()
    let counter = nextSendCounter
    nextSendCounter &+= 1
    counterLock.unlock()
    return try sealControl(plaintext, counter: counter)
  }
  func sealControl(_ plaintext: Data, counter: UInt64) throws -> Data {
    let plaintext = Data(plaintext)
    let nonce = try controlNonce(counter)
    do {
      let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
      return littleEndian(counter) + box.ciphertext + box.tag
    } catch { throw SessionCryptoError.authenticationFailed }
  }
  public func openControl(_ body: Data) throws -> Data {
    let body = Data(body)
    guard body.count >= 24 else { throw SessionCryptoError.invalidControlFrame }
    let counter = readLE64(body, 0)
    counterLock.lock()
    guard counter == nextReceiveCounter else {
      let expected = nextReceiveCounter
      counterLock.unlock()
      throw SessionCryptoError.counterMismatch(expected: expected, actual: counter)
    }
    do {
      let plain = try openControl(body, counter: counter)
      nextReceiveCounter &+= 1
      counterLock.unlock()
      return plain
    } catch {
      counterLock.unlock()
      throw error
    }
  }
  public func openControl(_ body: Data, counter: UInt64) throws -> Data {
    let body = Data(body)
    guard body.count >= 24, readLE64(body, 0) == counter else { throw SessionCryptoError.invalidControlFrame }
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: try controlNonce(counter), ciphertext: Data(body.dropFirst(8).dropLast(16)),
        tag: Data(body.suffix(16)))
      return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    } catch { throw SessionCryptoError.authenticationFailed }
  }

  public func sealSample(_ plaintext: Data, sequence: UInt32) throws -> Data {
    let plaintext = Data(plaintext)
    guard plaintext.count == 40 else { throw SessionCryptoError.invalidSampleFrame }
    if let sample = try? PenSample(decoding: Array(plaintext)), sample.flags.contains(.predicted) {
      throw SessionCryptoError.invalidSampleFrame
    }
    let digest = SHA256.hash(data: plaintext).withUnsafeBytes { Data($0) }
    sampleLock.lock()
    guard !sampleWrapped else {
      sampleLock.unlock()
      throw SessionCryptoError.sequenceWrap
    }
    guard sequence != .max else {
      sampleWrapped = true
      sampleLock.unlock()
      throw SessionCryptoError.sequenceWrap
    }
    if let last = lastSample {
      if sequence == last.sequence {
        guard digest == last.digest else {
          sampleLock.unlock()
          throw SessionCryptoError.sequenceReplay
        }
      } else {
        guard sequence > last.sequence else {
          sampleLock.unlock()
          throw SessionCryptoError.sequenceReplay
        }
      }
    }
    let box: ChaChaPoly.SealedBox
    do {
      box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: try sampleNonce(sequence))
    } catch {
      sampleLock.unlock()
      throw SessionCryptoError.authenticationFailed
    }
    lastSample = (sequence, digest)
    sampleLock.unlock()
    return littleEndian(sequence) + box.ciphertext + box.tag
  }
  public func openSample(_ packet: Data) throws -> (sequence: UInt32, plaintext: Data) {
    let packet = Data(packet)
    guard packet.count == 60 else { throw SessionCryptoError.invalidSampleFrame }
    let sequence = readLE32(packet, 0)
    guard sequence != .max else { throw SessionCryptoError.sequenceWrap }
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: try sampleNonce(sequence), ciphertext: Data(packet.dropFirst(4).dropLast(16)),
        tag: Data(packet.suffix(16)))
      return (sequence, try ChaChaPoly.open(box, using: SymmetricKey(data: key)))
    } catch { throw SessionCryptoError.authenticationFailed }
  }
  public func controlNonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
    try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + littleEndian(counter))
  }
  public func sampleNonce(_ sequence: UInt32) throws -> ChaChaPoly.Nonce {
    try ChaChaPoly.Nonce(data: epoch + littleEndian(sequence))
  }
  private func littleEndian(_ v: UInt64) -> Data {
    var x = v.littleEndian
    return withUnsafeBytes(of: &x) { Data($0) }
  }
  private func littleEndian(_ v: UInt32) -> Data {
    var x = v.littleEndian
    return withUnsafeBytes(of: &x) { Data($0) }
  }
  private func readLE64(_ d: Data, _ o: Int) -> UInt64 {
    d[o..<o + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (UInt64($1.offset) * 8) }
  }
  private func readLE32(_ d: Data, _ o: Int) -> UInt32 {
    d[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (UInt32($1.offset) * 8) }
  }
}

public final class SessionCipher: @unchecked Sendable {
  public let role: PairingRole
  private let outboundControl: SessionSealer
  private let inboundControl: SessionSealer
  private let outboundSample: SessionSealer
  private let inboundSample: SessionSealer
  public init(pairKey: Data, ipadNonce: Data, hostNonce: Data, role: PairingRole) throws {
    let material = try SessionKeyMaterial(pairKey: pairKey, ipadNonce: ipadNonce, hostNonce: hostNonce)
    self.role = role
    switch role {
    case .device:
      outboundControl = try SessionSealer(
        key: material.ipadToHostControl, epoch: material.epoch, direction: .ipadToHost)
      inboundControl = try SessionSealer(
        key: material.hostToIpadControl, epoch: material.epoch, direction: .hostToIpad)
      outboundSample = try SessionSealer(
        key: material.ipadToHostSample, epoch: material.epoch, direction: .ipadToHost)
      inboundSample = try SessionSealer(
        key: material.hostToIpadSample, epoch: material.epoch, direction: .hostToIpad)
    case .host:
      outboundControl = try SessionSealer(
        key: material.hostToIpadControl, epoch: material.epoch, direction: .hostToIpad)
      inboundControl = try SessionSealer(
        key: material.ipadToHostControl, epoch: material.epoch, direction: .ipadToHost)
      outboundSample = try SessionSealer(
        key: material.hostToIpadSample, epoch: material.epoch, direction: .hostToIpad)
      inboundSample = try SessionSealer(
        key: material.ipadToHostSample, epoch: material.epoch, direction: .ipadToHost)
    }
  }
  public func sealControl(_ plaintext: Data) throws -> Data { try outboundControl.sealControl(plaintext) }
  public func openControl(_ body: Data) throws -> Data { try inboundControl.openControl(body) }
  public func sealSample(_ plaintext: Data, sequence: UInt32) throws -> Data {
    try outboundSample.sealSample(plaintext, sequence: sequence)
  }
  public func openSample(_ packet: Data) throws -> (sequence: UInt32, plaintext: Data) {
    try inboundSample.openSample(packet)
  }
}
