import Foundation
import Network

/// iPad-side TCP listener used by usbmuxd. The listener is intentionally
/// loopback-only: usbmuxd forwards a cable connection through localhost.
@MainActor
public final class UsbLinkListener {
  public typealias StateHandler = @MainActor (Bool) -> Void
  public private(set) var isConnected = false
  public var stateHandler: StateHandler?

  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "dev.yukai.nib.usb-listener")
  private var listener: NWListener?
  private var connection: NWConnection?
  private var framer = StreamFramer()
  private var hello: ControlMessage.Hello?
  private var lastTrafficAt: TimeInterval?
  private var heartbeatTask: Task<Void, Never>?

  public init(port: UInt16 = 47811) {
    self.port = NWEndpoint.Port(rawValue: port)!
  }

  public func start(hello: ControlMessage.Hello) {
    self.hello = hello
    stop()
    do {
      let tcp = NWProtocolTCP.Options()
      tcp.noDelay = true
      let parameters = NWParameters(tls: nil, tcp: tcp)
      let newListener = try NWListener(using: parameters, on: port)
      newListener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in self?.accept(connection) }
      }
      newListener.start(queue: queue)
      listener = newListener
    } catch {
      stateHandler?(false)
    }
  }

  public func stop() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    listener?.cancel()
    listener = nil
    connection?.cancel()
    connection = nil
    lastTrafficAt = nil
    setConnected(false)
  }

  public func send(_ sample: PenSample) {
    guard isConnected, let connection else { return }
    connection.send(
      content: Data(StreamFramer.encode(.sample(sample))), completion: .contentProcessed { _ in })
  }

  public func send(_ message: ControlMessage) {
    guard let connection else { return }
    connection.send(
      content: Data(StreamFramer.encode(.control(message))), completion: .contentProcessed { _ in })
  }

  private func accept(_ newConnection: NWConnection) {
    connection?.cancel()
    connection = newConnection
    framer = StreamFramer()
    newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
      guard case .ready = state, let newConnection else { return }
      Task { @MainActor [weak self] in
        guard let self, self.connection === newConnection else { return }
        guard case .hostPort(let host, _) = newConnection.currentPath?.remoteEndpoint,
          USBPeerPolicy.allowsLoopbackPeer(String(describing: host))
        else {
          newConnection.cancel()
          return
        }
        self.send(
          .hello(
            self.hello
              ?? .init(
                appVersion: "0.1.0", deviceName: "NibPad", surfaceWidth: 0, surfaceHeight: 0)))
      }
    }
    newConnection.start(queue: queue)
    receive(from: newConnection)
  }

  private func receive(from expected: NWConnection) {
    expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self, self.connection === expected else { return }
        if let data, !data.isEmpty {
          self.lastTrafficAt = Date.timeIntervalSinceReferenceDate
          do {
            for frame in try self.framer.append(Array(data)) {
              guard case .control(let message) = frame else { continue }
              switch message {
              case .helloAck(let ack):
                self.setConnected(ack.accepted)
                if ack.accepted { self.startHeartbeat() }
              case .probe(let sentAtNs): self.send(.probeReply(sentAtNs: sentAtNs))
              default: break
              }
            }
          } catch {
            self.drop(expected)
            return
          }
        }
        if complete || error != nil { self.drop(expected) } else { self.receive(from: expected) }
      }
    }
  }

  private func drop(_ expected: NWConnection) {
    guard connection === expected else { return }
    expected.cancel()
    connection = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
    lastTrafficAt = nil
    setConnected(false)
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    lastTrafficAt = Date.timeIntervalSinceReferenceDate
    heartbeatTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled, self.isConnected else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if USBHeartbeatPolicy.isTimedOut(lastTraffic: self.lastTrafficAt, now: now) {
          if let connection = self.connection { self.drop(connection) }
          return
        }
        self.send(.ping)
      }
    }
  }

  private func setConnected(_ value: Bool) {
    guard isConnected != value else { return }
    isConnected = value
    stateHandler?(value)
  }
}
