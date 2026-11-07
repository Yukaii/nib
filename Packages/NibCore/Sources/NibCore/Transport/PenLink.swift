import Foundation
import Network

public enum PenLinkState: Sendable, Equatable {
  case searching, connecting
  case connected(String)
  case rejected(String)
}
public enum PenLinkSessionEvent: Sendable, Equatable {
  case connected(ControlMessage.Hello)
  case geometryChanged(ControlMessage.Geometry)
  case disconnected
}

@MainActor
public final class PenLinkSender {
  public typealias StateHandler = @MainActor (PenLinkState) -> Void
  public private(set) var state: PenLinkState = .searching { didSet { stateHandler?(state) } }
  public var stateHandler: StateHandler?
  private let browser: NWBrowser
  private var connection: NWConnection?
  private var udpConnection: NWConnection?
  private var framer = ControlFramer()
  private var hello: ControlMessage.Hello?
  private var reconnectTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private let queue = DispatchQueue(label: "dev.yukai.nib.sender")

  public init() {
    browser = NWBrowser(for: .bonjour(type: "_nib._tcp", domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor [weak self] in self?.found(results.first) }
    }
    browser.stateUpdateHandler = { [weak self] newState in
      if case .failed = newState { Task { @MainActor [weak self] in self?.scheduleReconnect() } }
    }
  }

  public func start(hello: ControlMessage.Hello) {
    self.hello = hello
    state = .searching
    browser.start(queue: queue)
  }

  public func stop() {
    reconnectTask?.cancel()
    reconnectTask = nil
    pingTask?.cancel()
    pingTask = nil
    browser.cancel()
    connection?.cancel()
    udpConnection?.cancel()
    connection = nil
    udpConnection = nil
    state = .searching
  }

  public func send(_ sample: PenSample) {
    guard let udpConnection else { return }
    let payload = Data(sample.encode())
    let count = [.down, .up, .cancel, .proximityExit].contains(sample.kind) ? 3 : 1
    for _ in 0..<count {
      udpConnection.send(content: payload, completion: .contentProcessed { _ in })
    }
  }

  public func updateGeometry(width: Double, height: Double) {
    sendControl(.geometry(.init(surfaceWidth: width, surfaceHeight: height)))
  }

  public func ping() { sendControl(.ping) }

  private func found(_ result: NWBrowser.Result?) {
    guard connection == nil, let result else { return }
    state = .connecting
    let endpoint: NWEndpoint
    switch result.endpoint {
    case .service(let name, let type, let domain, let interface):
      endpoint = .service(name: name, type: type, domain: domain, interface: interface)
    default: return
    }
    let newConnection = NWConnection(to: endpoint, using: .tcp)
    connection = newConnection
    newConnection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if case .failed = state {
          self.connection = nil
          self.scheduleReconnect()
        }
      }
    }
    newConnection.start(queue: queue)
    receiveControl()
    sendControl(
      .hello(hello ?? .init(appVersion: "0.1.0", deviceName: "NibPad", surfaceWidth: 0, surfaceHeight: 0)))
  }

  private func sendControl(_ message: ControlMessage) {
    guard let connection else { return }
    connection.send(content: Data(ControlFramer().encode(message)), completion: .contentProcessed { _ in })
  }

  private func receiveControl() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let data, !data.isEmpty {
          do {
            for message in try self.framer.append(Array(data)) { self.handle(message) }
          } catch {
            self.connection?.cancel()
            self.connection = nil
            self.scheduleReconnect()
          }
        }
        if !isComplete, error == nil {
          self.receiveControl()
        } else if error != nil {
          self.connection = nil
          self.scheduleReconnect()
        }
      }
    }
  }

  private func handle(_ message: ControlMessage) {
    guard case .helloAck(let ack) = message else { return }
    guard ack.accepted, let connection else {
      state = .rejected(ack.reason ?? "rejected")
      connection?.cancel()
      self.connection = nil
      return
    }
    guard let remote = connection.currentPath?.remoteEndpoint,
      case .hostPort(let host, _) = remote
    else { return }
    let udp = NWConnection(
      to: .hostPort(host: host, port: NWEndpoint.Port(rawValue: ack.udpPort) ?? .any), using: .udp)
    udpConnection = udp
    udp.start(queue: queue)
    state = .connected("Nib")
    pingTask?.cancel()
    pingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        self.ping()
      }
    }
  }

  private func scheduleReconnect() {
    guard reconnectTask == nil else { return }
    state = .searching
    pingTask?.cancel()
    pingTask = nil
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self else { return }
      self.reconnectTask = nil
      self.browser.cancel()
      self.browser.start(queue: self.queue)
    }
  }
}

@MainActor
public final class PenLinkReceiver {
  public typealias AcceptHandler = @MainActor (ControlMessage.Hello) async -> Bool
  public typealias SampleHandler = @MainActor (PenSample) -> Void
  public typealias SessionHandler = @MainActor (PenLinkSessionEvent) -> Void
  public var accept: AcceptHandler
  public var onSample: SampleHandler?
  public var onSession: SessionHandler?
  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.yukai.nib.receiver")
  private var connection: NWConnection?
  private var udpListener: NWListener?
  private var framer = ControlFramer()
  private var sequencer = SampleSequencer()
  private var remoteHost: NWEndpoint?

  public init(accept: @escaping AcceptHandler = { _ in true }) throws {
    self.accept = accept
    listener = try NWListener(using: .tcp)
    listener.service = NWListener.Service(name: ProcessInfo.processInfo.hostName, type: "_nib._tcp")
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor [weak self] in self?.acceptConnection(connection) }
    }
  }

  public func start() {
    listener.stateUpdateHandler = { _ in }
    listener.start(queue: queue)
    do {
      let udp = try NWListener(using: .udp)
      udp.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in self?.acceptUDP(connection) }
      }
      udp.start(queue: queue)
      udpListener = udp
    } catch {}
  }
  public func stop() {
    listener.cancel()
    udpListener?.cancel()
    connection?.cancel()
    onSession?(.disconnected)
  }

  private func acceptConnection(_ newConnection: NWConnection) {
    connection?.cancel()
    connection = newConnection
    framer = ControlFramer()
    sequencer.reset()
    remoteHost = newConnection.currentPath?.remoteEndpoint
    newConnection.start(queue: queue)
    receiveControl()
  }
  private func receiveControl() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let data, !data.isEmpty {
          do { for message in try self.framer.append(Array(data)) { await self.handle(message) } } catch {
            self.connection?.cancel()
          }
        }
        if !complete, error == nil { self.receiveControl() } else { self.onSession?(.disconnected) }
      }
    }
  }
  private func handle(_ message: ControlMessage) async {
    switch message {
    case .hello(let hello):
      guard await accept(hello) else {
        sendControl(.helloAck(.init(accepted: false, reason: "rejected")))
        onSession?(.disconnected)
        return
      }
      let port = udpListener?.port?.rawValue ?? 0
      sendControl(.helloAck(.init(accepted: true, udpPort: port, displayWidth: 0, displayHeight: 0)))
      onSession?(.connected(hello))
    case .geometry(let value): onSession?(.geometryChanged(value))
    case .ping: sendControl(.ping)
    case .helloAck: break
    }
  }
  private func sendControl(_ message: ControlMessage) {
    guard let connection else { return }
    connection.send(content: Data(ControlFramer().encode(message)), completion: .contentProcessed { _ in })
  }
  private func acceptUDP(_ newConnection: NWConnection) {
    guard connection != nil else {
      newConnection.cancel()
      return
    }
    newConnection.start(queue: queue)
    receiveUDP(newConnection)
  }
  private func receiveUDP(_ udp: NWConnection) {
    udp.receiveMessage { [weak self] data, _, _, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let data, data.count == PenSample.byteCount, let sample = try? PenSample(decoding: Array(data)),
          self.sequencer.accept(sample)
        {
          self.onSample?(sample)
        }
        if error == nil { self.receiveUDP(udp) }
      }
    }
  }
}
