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
  private let transport: LinkByteTransport
  private let onMessage: @Sendable (ControlMessage) -> Void

  public init(
    transport: LinkByteTransport, onMessage: @escaping @Sendable (ControlMessage) -> Void
  ) {
    self.transport = transport
    self.onMessage = onMessage
  }

  public func receive(_ bytes: Data) throws {
    for message in try framer.append(Array(bytes)) { onMessage(message) }
  }

  public func send(_ message: ControlMessage) {
    transport.send(bytes: Data(ControlFramer().encode(message)))
  }

  public func close() { transport.close() }
}

/// Shared stream receive/dispatch path for USB links. Samples are delivered
/// separately so the hot sample path can remain allocation-free in production.
public final class StreamLinkDispatcher: @unchecked Sendable {
  private var framer = StreamFramer()
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
    for frame in try framer.append(Array(bytes)) {
      switch frame {
      case .control(let message): onControl(message)
      case .sample(let sample): onSample(sample)
      }
    }
  }

  public func send(_ message: ControlMessage) {
    transport.send(bytes: Data(StreamFramer.encode(.control(message))))
  }

  public func send(_ sample: PenSample) {
    transport.send(bytes: Data(StreamFramer.encode(.sample(sample))))
  }

  public func close() { transport.close() }
}
