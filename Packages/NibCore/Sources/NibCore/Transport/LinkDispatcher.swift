import Foundation
import Network

/// The byte-level contract used by a control or USB connection. Keeping this
/// small makes the production framer/dispatch path runnable with an in-memory
/// peer in deterministic tests.
public protocol LinkByteTransport: AnyObject, Sendable {
  func send(bytes: Data)
  func close()
}

/// NWConnection adapter used by the app transports. It contains no protocol
/// policy; the dispatcher owns framing and message routing.
@available(macOS 14, iOS 18, *)
public final class NWLinkByteTransport: LinkByteTransport, @unchecked Sendable {
  private let connection: NWConnection

  public init(_ connection: NWConnection) { self.connection = connection }

  public func send(bytes: Data) {
    connection.send(content: bytes, completion: .contentProcessed { _ in })
  }

  public func close() { connection.cancel() }
}

/// Shared control receive/dispatch path for Wi-Fi links.
public final class ControlLinkDispatcher: @unchecked Sendable {
  private var framer = ControlFramer()
  private var encryptedBytes = Data()
  private var session: SessionCipher?
  private let transport: LinkByteTransport
  private let onMessage: @Sendable (ControlMessage) -> Void

  public init(
    transport: LinkByteTransport, onMessage: @escaping @Sendable (ControlMessage) -> Void
  ) {
    self.transport = transport
    self.onMessage = onMessage
  }

  public func receive(_ bytes: Data) throws {
    if session != nil {
      encryptedBytes.append(bytes)
      try receiveEncrypted()
      return
    }
    for message in try framer.append(Array(bytes)) { onMessage(message) }
  }

  /// Begins after the authenticated helloAck has been sent or verified. The
  /// hello and helloAck themselves remain plaintext for compatibility with the
  /// pairing state machine.
  public func configureSession(_ session: SessionCipher) {
    self.session = session
    encryptedBytes.removeAll(keepingCapacity: true)
  }

  public func clearSession() {
    session = nil
    encryptedBytes.removeAll(keepingCapacity: true)
  }

  public func send(_ message: ControlMessage) {
    let plaintext = Data(ControlFramer().encode(message))
    if var session {
      do {
        let body = try session.sealControl(Data(plaintext.dropFirst(4)))
        self.session = session
        transport.send(bytes: frame(body))
      } catch { transport.close() }
    } else {
      transport.send(bytes: plaintext)
    }
  }

  public func close() { transport.close() }

  private func receiveEncrypted() throws {
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
      guard var session else { throw SessionCryptoError.invalidControlFrame }
      let plaintext = try session.openControl(body)
      self.session = session
      let plaintextFrame = frame(plaintext)
      for message in try framer.append(Array(plaintextFrame)) { onMessage(message) }
    }
  }

  private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).littleEndian
    return Data(withUnsafeBytes(of: &length) { Data($0) }) + body
  }

  private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
    data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (UInt32($1.offset) * 8) }
  }
}

/// Shared stream receive/dispatch path for USB links. Samples are delivered
/// separately so the hot sample path can remain allocation-free in production.
public final class StreamLinkDispatcher: @unchecked Sendable {
  private var framer = StreamFramer()
  private var encryptedBytes = Data()
  private var session: SessionCipher?
  private let transport: LinkByteTransport
  private let onControl: @Sendable (ControlMessage) -> Void
  private let onSample: @Sendable (PenSample) -> Void

  public init(
    transport: LinkByteTransport,
    onControl: @escaping @Sendable (ControlMessage) -> Void,
    onSample: @escaping @Sendable (PenSample) -> Void
  ) {
    self.transport = transport
    self.onControl = onControl
    self.onSample = onSample
  }

  public func receive(_ bytes: Data) throws {
    if session != nil {
      encryptedBytes.append(bytes)
      try receiveEncrypted()
      return
    }
    for frame in try framer.append(Array(bytes)) {
      switch frame {
      case .control(let message): onControl(message)
      case .sample(let sample): onSample(sample)
      }
    }
  }

  public func send(_ message: ControlMessage) {
    let plaintext = Data(ControlFramer().encode(message)).dropFirst(4)
    if var session {
      do {
        let body = try session.sealControl(Data(plaintext))
        self.session = session
        transport.send(bytes: Data([StreamFramer.controlType]) + frame(body))
      } catch { transport.close() }
    } else {
      transport.send(bytes: Data(StreamFramer.encode(.control(message))))
    }
  }

  public func send(_ sample: PenSample) {
    if let session {
      do {
        let body = try session.sealSample(Data(sample.encode()), sequence: sample.sequence)
        transport.send(bytes: Data([StreamFramer.sampleType]) + body)
      } catch { transport.close() }
    } else {
      transport.send(bytes: Data(StreamFramer.encode(.sample(sample))))
    }
  }

  public func close() { transport.close() }

  public func configureSession(_ session: SessionCipher) {
    self.session = session
    encryptedBytes.removeAll(keepingCapacity: true)
  }

  public func clearSession() {
    session = nil
    encryptedBytes.removeAll(keepingCapacity: true)
  }

  private func receiveEncrypted() throws {
    while true {
      guard let type = encryptedBytes.first else { return }
      if type == StreamFramer.sampleType {
        let total = 1 + 4 + 40 + 16
        guard encryptedBytes.count >= total else { return }
        let packet = Data(encryptedBytes[1..<total])
        encryptedBytes.removeFirst(total)
        guard let session else { throw SessionCryptoError.invalidSampleFrame }
        let opened = try session.openSample(packet)
        guard let sample = try? PenSample(decoding: Array(opened.plaintext)) else {
          throw SessionCryptoError.invalidSampleFrame
        }
        guard sample.sequence == opened.sequence else { throw SessionCryptoError.invalidSampleFrame }
        onSample(sample)
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
        guard var session else { throw SessionCryptoError.invalidControlFrame }
        let plaintext = try session.openControl(body)
        self.session = session
        var controlFramer = ControlFramer()
        for message in try controlFramer.append(Array(frame(plaintext))) { onControl(message) }
      } else {
        throw StreamFramer.Error.unknownType(type)
      }
    }
  }

  private func frame(_ body: Data) -> Data {
    var length = UInt32(body.count).littleEndian
    return Data(withUnsafeBytes(of: &length) { Data($0) }) + body
  }

  private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
    data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (UInt32($1.offset) * 8) }
  }
}
