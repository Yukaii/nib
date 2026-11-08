import Foundation
import Network

public protocol LinkByteTransport: AnyObject, Sendable {
  func send(bytes: Data)
  func close()
}

@available(macOS 14, iOS 18, *)
public final class NWLinkByteTransport: LinkByteTransport, @unchecked Sendable {
  private let connection: NWConnection
  public init(_ connection: NWConnection) { self.connection = connection }
  public func send(bytes: Data) { connection.send(content: bytes, completion: .contentProcessed { _ in }) }
  public func close() { connection.cancel() }
}

private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
  UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
    | UInt32(data[offset + 3]) << 24
}

public final class ControlLinkDispatcher: @unchecked Sendable {
  private let lock = NSLock()
  private var framer = ControlFramer()
  private var encryptedBytes = Data()
  private var encryptedOffset = 0
  private var session: SessionCipher?
  private let transport: LinkByteTransport
  private let onMessage: @Sendable (ControlMessage) -> Void
  private let armSession: (@Sendable (ControlMessage) -> SessionCipher?)?

  public init(
    transport: LinkByteTransport, armSession: (@Sendable (ControlMessage) -> SessionCipher?)? = nil,
    onMessage: @escaping @Sendable (ControlMessage) -> Void
  ) {
    self.transport = transport
    self.armSession = armSession
    self.onMessage = onMessage
  }
  public func receive(_ bytes: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    var messages: [ControlMessage] = []
    if session != nil {
      encryptedBytes.append(bytes)
      try receiveEncryptedLocked(into: &messages)
    } else {
      var first = try framer.appendOne(Array(bytes))
      var armed = false
      while true {
        let result: ControlFramer.AppendOneResult
        if first != .needMore {
          result = first
          first = .needMore
        } else {
          result = try framer.appendOne([])
        }
        switch result {
        case .needMore: break
        case .skipped: continue
        case .message(let message):
          messages.append(message)
          if case .helloAck(let ack) = message, ack.accepted, let cipher = armSession?(message) {
            session = cipher
            encryptedBytes.append(framer.takeBufferedBytes())
            try receiveEncryptedLocked(into: &messages)
            armed = true
          }
        }
        if result == .needMore || armed { break }
      }
    }
    lock.unlock()
    for message in messages { onMessage(message) }
    lock.lock()
  }
  public func configureSession(_ session: SessionCipher) {
    lock.lock()
    self.session = session
    encryptedBytes.append(framer.takeBufferedBytes())
    lock.unlock()
  }
  public func clearSession() {
    lock.lock()
    session = nil
    encryptedBytes.removeAll(keepingCapacity: true)
    encryptedOffset = 0
    lock.unlock()
  }
  public func send(_ message: ControlMessage) {
    let plaintext = Data(ControlFramer().encode(message))
    lock.lock()
    let current = session
    lock.unlock()
    if let current {
      do { transport.send(bytes: frame(try current.sealControl(Data(plaintext.dropFirst(4))))) } catch {
        transport.close()
      }
    } else {
      transport.send(bytes: plaintext)
    }
  }
  public func close() { transport.close() }
  private func receiveEncryptedLocked(into messages: inout [ControlMessage]) throws {
    while true {
      guard encryptedBytes.count >= 4 else { return }
      let available = encryptedBytes.count - encryptedOffset
      guard available >= 4 else { return }
      let length = readLE32(encryptedBytes, encryptedOffset)
      guard length >= 24, length <= ControlFramer.maximumMessageSize + 24 else {
        throw SessionCryptoError.invalidControlFrame
      }
      let total = 4 + Int(length)
      guard available >= total else { return }
      let start = encryptedOffset
      let body = Data(encryptedBytes[(start + 4)..<(start + total)])
      encryptedOffset += total
      compactEncryptedBufferIfNeeded()
      guard let current = session else { throw SessionCryptoError.invalidControlFrame }
      let plaintext = try current.openControl(body)
      var plainFramer = ControlFramer()
      if case .message(let message) = try plainFramer.appendOne(Array(frame(plaintext))) {
        messages.append(message)
      }
    }
  }
  private func compactEncryptedBufferIfNeeded() {
    guard encryptedOffset > 0,
      encryptedOffset >= 64 * 1024 || encryptedOffset * 2 >= encryptedBytes.count
    else { return }
    encryptedBytes = Data(encryptedBytes[encryptedOffset...])
    encryptedOffset = 0
  }
  private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).littleEndian
    return Data(withUnsafeBytes(of: &length) { Data($0) }) + body
  }
}

public final class StreamLinkDispatcher: @unchecked Sendable {
  private let lock = NSLock()
  private var framer = StreamFramer()
  private var encryptedBytes = Data()
  private var encryptedOffset = 0
  private var session: SessionCipher?
  private let transport: LinkByteTransport
  private let onControl: @Sendable (ControlMessage) -> Void
  private let onSample: @Sendable (PenSample) -> Void
  private let armSession: (@Sendable (ControlMessage) -> SessionCipher?)?
  public init(
    transport: LinkByteTransport, armSession: (@Sendable (ControlMessage) -> SessionCipher?)? = nil,
    onControl: @escaping @Sendable (ControlMessage) -> Void, onSample: @escaping @Sendable (PenSample) -> Void
  ) {
    self.transport = transport
    self.armSession = armSession
    self.onControl = onControl
    self.onSample = onSample
  }
  public func receive(_ bytes: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    var controls: [ControlMessage] = []
    var samples: [PenSample] = []
    if session != nil {
      encryptedBytes.append(bytes)
      try receiveEncryptedLocked(controls: &controls, samples: &samples)
    } else {
      var first = try framer.appendOne(Array(bytes))
      var armed = false
      while true {
        let result: StreamFramer.AppendOneResult
        if first != .needMore {
          result = first
          first = .needMore
        } else {
          result = try framer.appendOne([])
        }
        switch result {
        case .needMore: break
        case .skipped: continue
        case .frame(let item):
          switch item {
          case .sample(let sample): samples.append(sample)
          case .control(let message):
            controls.append(message)
            if case .helloAck(let ack) = message, ack.accepted, let cipher = armSession?(message) {
              session = cipher
              encryptedBytes.append(framer.takeBufferedBytes())
              try receiveEncryptedLocked(controls: &controls, samples: &samples)
              armed = true
            }
          }
        }
        if result == .needMore || armed { break }
      }
    }
    lock.unlock()
    controls.forEach(onControl)
    samples.forEach(onSample)
    lock.lock()
  }
  public func send(_ message: ControlMessage) {
    let body = Data(ControlFramer().encode(message)).dropFirst(4)
    lock.lock()
    let current = session
    lock.unlock()
    if let current {
      do {
        transport.send(bytes: Data([StreamFramer.controlType]) + frame(try current.sealControl(Data(body))))
      } catch { transport.close() }
    } else {
      transport.send(bytes: Data(StreamFramer.encode(.control(message))))
    }
  }
  public func send(_ sample: PenSample) {
    lock.lock()
    let current = session
    lock.unlock()
    if let current {
      do {
        transport.send(
          bytes: Data([StreamFramer.sampleType])
            + (try current.sealSample(Data(sample.encode()), sequence: sample.sequence)))
      } catch { transport.close() }
    } else {
      transport.send(bytes: Data(StreamFramer.encode(.sample(sample))))
    }
  }
  public func close() { transport.close() }
  public func configureSession(_ session: SessionCipher) {
    lock.lock()
    self.session = session
    encryptedBytes.append(framer.takeBufferedBytes())
    lock.unlock()
  }
  public func clearSession() {
    lock.lock()
    session = nil
    encryptedBytes.removeAll(keepingCapacity: true)
    encryptedOffset = 0
    lock.unlock()
  }
  private func receiveEncryptedLocked(controls: inout [ControlMessage], samples: inout [PenSample]) throws {
    while true {
      guard encryptedOffset < encryptedBytes.count else { return }
      let type = encryptedBytes[encryptedOffset]
      if type == StreamFramer.sampleType {
        let total = 1 + 4 + 40 + 16
        guard encryptedBytes.count - encryptedOffset >= total else { return }
        let start = encryptedOffset
        let packet = Data(encryptedBytes[(start + 1)..<(start + total)])
        encryptedOffset += total
        compactEncryptedBufferIfNeeded()
        guard let current = session else { throw SessionCryptoError.invalidSampleFrame }
        let opened = try current.openSample(packet)
        let sample = try PenSample(decoding: Array(opened.plaintext))
        guard sample.sequence == opened.sequence else { throw SessionCryptoError.invalidSampleFrame }
        samples.append(sample)
      } else if type == StreamFramer.controlType {
        guard encryptedBytes.count - encryptedOffset >= 5 else { return }
        let start = encryptedOffset
        let length = readLE32(encryptedBytes, start + 1)
        guard length >= 24, length <= ControlFramer.maximumMessageSize + 24 else {
          throw SessionCryptoError.invalidControlFrame
        }
        let total = 1 + 4 + Int(length)
        guard encryptedBytes.count - encryptedOffset >= total else { return }
        let body = Data(encryptedBytes[(start + 5)..<(start + total)])
        encryptedOffset += total
        compactEncryptedBufferIfNeeded()
        guard let current = session else { throw SessionCryptoError.invalidControlFrame }
        let plain = try current.openControl(body)
        var cf = ControlFramer()
        if case .message(let message) = try cf.appendOne(Array(frame(plain))) {
          controls.append(message)
        }
      } else {
        throw StreamFramer.Error.unknownType(type)
      }
    }
  }
  private func compactEncryptedBufferIfNeeded() {
    guard encryptedOffset > 0,
      encryptedOffset >= 64 * 1024 || encryptedOffset * 2 >= encryptedBytes.count
    else { return }
    encryptedBytes = Data(encryptedBytes[encryptedOffset...])
    encryptedOffset = 0
  }
  private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).littleEndian
    return Data(withUnsafeBytes(of: &length) { Data($0) }) + body
  }
}
