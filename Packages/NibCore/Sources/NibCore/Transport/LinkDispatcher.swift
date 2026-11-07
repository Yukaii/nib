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
  data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (UInt32($1.offset) * 8) }
}

public final class ControlLinkDispatcher: @unchecked Sendable {
  private let lock = NSLock()
  private var framer = ControlFramer()
  private var encryptedBytes = Data()
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
      while true {
        let message: ControlMessage
        if let pending = first {
          message = pending
          first = nil
        } else {
          guard let next = try framer.appendOne([]) else { break }
          message = next
        }
        messages.append(message)
        if case .helloAck(let ack) = message, ack.accepted, let cipher = armSession?(message) {
          session = cipher
          encryptedBytes.append(framer.takeBufferedBytes())
          try receiveEncryptedLocked(into: &messages)
          break
        }
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
      let length = readLE32(encryptedBytes, 0)
      guard length >= 24, length <= ControlFramer.maximumMessageSize + 24 else {
        throw SessionCryptoError.invalidControlFrame
      }
      let total = 4 + Int(length)
      guard encryptedBytes.count >= total else { return }
      let body = Data(encryptedBytes[4..<total])
      encryptedBytes.removeFirst(total)
      guard let current = session else { throw SessionCryptoError.invalidControlFrame }
      let plaintext = try current.openControl(body)
      var plainFramer = ControlFramer()
      if let message = try plainFramer.appendOne(Array(frame(plaintext))) { messages.append(message) }
    }
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
      while true {
        let item: StreamFrame
        if let pending = first {
          item = pending
          first = nil
        } else {
          guard let next = try framer.appendOne([]) else { break }
          item = next
        }
        switch item {
        case .sample(let sample): samples.append(sample)
        case .control(let message):
          controls.append(message)
          if case .helloAck(let ack) = message, ack.accepted, let cipher = armSession?(message) {
            session = cipher
            encryptedBytes.append(framer.takeBufferedBytes())
            try receiveEncryptedLocked(controls: &controls, samples: &samples)
            break
          }
        }
        if session != nil { break }
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
    lock.unlock()
  }
  private func receiveEncryptedLocked(controls: inout [ControlMessage], samples: inout [PenSample]) throws {
    while true {
      guard let type = encryptedBytes.first else { return }
      if type == StreamFramer.sampleType {
        let total = 1 + 4 + 40 + 16
        guard encryptedBytes.count >= total else { return }
        let packet = Data(encryptedBytes[1..<total])
        encryptedBytes.removeFirst(total)
        guard let current = session else { throw SessionCryptoError.invalidSampleFrame }
        let opened = try current.openSample(packet)
        let sample = try PenSample(decoding: Array(opened.plaintext))
        guard sample.sequence == opened.sequence else { throw SessionCryptoError.invalidSampleFrame }
        samples.append(sample)
      } else if type == StreamFramer.controlType {
        guard encryptedBytes.count >= 5 else { return }
        let length = readLE32(encryptedBytes, 1)
        guard length >= 24, length <= ControlFramer.maximumMessageSize + 24 else {
          throw SessionCryptoError.invalidControlFrame
        }
        let total = 1 + 4 + Int(length)
        guard encryptedBytes.count >= total else { return }
        let body = Data(encryptedBytes[5..<total])
        encryptedBytes.removeFirst(total)
        guard let current = session else { throw SessionCryptoError.invalidControlFrame }
        let plain = try current.openControl(body)
        var cf = ControlFramer()
        if let message = try cf.appendOne(Array(frame(plain))) { controls.append(message) }
      } else {
        throw StreamFramer.Error.unknownType(type)
      }
    }
  }
  private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).littleEndian
    return Data(withUnsafeBytes(of: &length) { Data($0) }) + body
  }
}
