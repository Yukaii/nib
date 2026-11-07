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

/// Pure session policy used by the receiver and its deterministic tests.
public struct ReceiverSession: Sendable, Equatable {
  public enum HelloDecision: Sendable, Equatable {
    case accepted
    case rejected(String)
  }

  public private(set) var accepted = false
  public private(set) var remoteHost: String?
  public private(set) var lastReceived: TimeInterval?
  private var disconnected = false
  private var sequencer = SampleSequencer()

  public init() {}

  public mutating func hello(
    protocolVersion: UInt8, busy: Bool, acceptResult: Bool, now: TimeInterval
  ) -> HelloDecision {
    guard !busy else { return .rejected("busy") }
    guard protocolVersion == PenSample.version else {
      return .rejected("Update the iPad app to the current version.")
    }
    guard acceptResult else { return .rejected("rejected") }
    accepted = true
    disconnected = false
    lastReceived = now
    sequencer.reset()
    return .accepted
  }

  public mutating func setRemoteHost(_ host: String) {
    remoteHost = host
  }

  public mutating func received(at now: TimeInterval) {
    guard accepted else { return }
    lastReceived = now
  }

  public mutating func acceptsUDP(from host: String, sequence: UInt32) -> Bool {
    guard accepted, let remoteHost, remoteHost == host else { return false }
    return sequencer.accept(
      .init(
        kind: .move, sequence: sequence, timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0,
        azimuth: 0))
  }

  public func heartbeatExpired(at now: TimeInterval) -> Bool {
    guard accepted, let lastReceived else { return false }
    return now - lastReceived >= 3
  }

  public mutating func timeoutIfNeeded(at now: TimeInterval) -> Bool {
    guard !disconnected, heartbeatExpired(at: now) else { return false }
    disconnected = true
    return true
  }

  public mutating func disconnect() {
    accepted = false
    remoteHost = nil
    lastReceived = nil
    disconnected = true
    sequencer.reset()
  }
}

@MainActor
public final class PenLinkSender {
  public typealias StateHandler = @MainActor (PenLinkState) -> Void
  public private(set) var state: PenLinkState = .searching { didSet { stateHandler?(state) } }
  public var stateHandler: StateHandler?

  private var browser: NWBrowser?
  private var latestResult: NWBrowser.Result?
  private var connection: NWConnection?
  private var udpConnection: NWConnection?
  private var framer = ControlFramer()
  private var hello: ControlMessage.Hello?
  private var lastReceivedAt: TimeInterval?
  private var lastGeometry: (Double, Double)?
  private var reconnectTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private let queue = DispatchQueue(label: "dev.yukai.nib.sender")

  public init() {}

  public func start(hello: ControlMessage.Hello) {
    self.hello = hello
    startBrowser()
  }

  public func stop() {
    reconnectTask?.cancel()
    reconnectTask = nil
    pingTask?.cancel()
    pingTask = nil
    browser?.cancel()
    browser = nil
    connection?.cancel()
    udpConnection?.cancel()
    connection = nil
    udpConnection = nil
    latestResult = nil
    lastReceivedAt = nil
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
    if let lastGeometry, lastGeometry.0 == width, lastGeometry.1 == height { return }
    lastGeometry = (width, height)
    hello?.surfaceWidth = width
    hello?.surfaceHeight = height
    guard connection != nil, case .connected = state else { return }
    sendControl(.geometry(.init(surfaceWidth: width, surfaceHeight: height)))
  }

  public func ping() { sendControl(.ping) }

  private func startBrowser() {
    browser?.cancel()
    let newBrowser = NWBrowser(for: .bonjour(type: "_nib._tcp", domain: nil), using: .tcp)
    browser = newBrowser
    newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.latestResult = results.first
        self.connect(to: results.first)
      }
    }
    newBrowser.stateUpdateHandler = { [weak self] newState in
      if case .failed = newState {
        Task { @MainActor [weak self] in self?.scheduleReconnect() }
      }
    }
    state = .searching
    newBrowser.start(queue: queue)
  }

  private func connect(to result: NWBrowser.Result?) {
    guard connection == nil, let result else { return }
    guard case .service(let name, let type, let domain, let interface) = result.endpoint else { return }
    state = .connecting
    let newConnection = NWConnection(
      to: .service(name: name, type: type, domain: domain, interface: interface), using: .tcp)
    connection = newConnection
    framer = ControlFramer()
    newConnection.stateUpdateHandler = { [weak self] newState in
      if case .failed = newState {
        Task { @MainActor [weak self] in self?.connectionLost() }
      }
    }
    newConnection.start(queue: queue)
    receiveControl(from: newConnection)
    sendControl(
      .hello(hello ?? .init(appVersion: "0.1.0", deviceName: "NibPad", surfaceWidth: 0, surfaceHeight: 0)))
  }

  private func receiveControl(from expected: NWConnection) {
    expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      Task { @MainActor [weak self] in
        guard let self, self.connection === expected else { return }
        if let data, !data.isEmpty {
          self.lastReceivedAt = Date.timeIntervalSinceReferenceDate
          do {
            for message in try self.framer.append(Array(data)) { self.handle(message) }
          } catch {
            self.connectionLost()
            return
          }
        }
        if isComplete || error != nil { self.connectionLost() } else { self.receiveControl(from: expected) }
      }
    }
  }

  private func handle(_ message: ControlMessage) {
    lastReceivedAt = Date.timeIntervalSinceReferenceDate
    switch message {
    case .helloAck(let ack):
      guard ack.accepted, let connection else {
        state = .rejected(ack.reason ?? "rejected")
        connectionLost(reconnect: false)
        return
      }
      guard let remote = connection.currentPath?.remoteEndpoint,
        case .hostPort(let host, _) = remote,
        let port = NWEndpoint.Port(rawValue: ack.udpPort)
      else {
        connectionLost()
        return
      }
      udpConnection?.cancel()
      let udp = NWConnection(to: .hostPort(host: host, port: port), using: .udp)
      udpConnection = udp
      udp.start(queue: queue)
      let name: String
      if case .service(let serviceName, _, _, _) = latestResult?.endpoint {
        name = serviceName
      } else {
        name = "Mac"
      }
      state = .connected(name)
      startHeartbeat()
    case .ping:
      sendControl(.ping)
    default: break
    }
  }

  private func sendControl(_ message: ControlMessage) {
    guard let connection else { return }
    connection.send(content: Data(ControlFramer().encode(message)), completion: .contentProcessed { _ in })
  }

  private func startHeartbeat() {
    pingTask?.cancel()
    lastReceivedAt = Date.timeIntervalSinceReferenceDate
    pingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if let last = self.lastReceivedAt, now - last >= 3 {
          self.connectionLost()
          return
        }
        self.ping()
      }
    }
  }

  private func connectionLost(reconnect: Bool = true) {
    connection?.cancel()
    udpConnection?.cancel()
    connection = nil
    udpConnection = nil
    lastReceivedAt = nil
    pingTask?.cancel()
    pingTask = nil
    guard reconnect else { return }
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard reconnectTask == nil else { return }
    state = .searching
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.reconnectTask = nil
      self.startBrowser()
      if let result = self.latestResult { self.connect(to: result) }
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
  private var session = ReceiverSession()
  private var heartbeatTask: Task<Void, Never>?
  private var sessionConnected = false
  private var busyFramers: [ObjectIdentifier: ControlFramer] = [:]

  public init(accept: @escaping AcceptHandler = { _ in true }) throws {
    self.accept = accept
    listener = try NWListener(using: .tcp)
    listener.service = NWListener.Service(type: "_nib._tcp")
    listener.newConnectionHandler = { [weak self] newConnection in
      Task { @MainActor [weak self] in self?.acceptConnection(newConnection) }
    }
  }

  public func start() {
    listener.stateUpdateHandler = { [weak self] state in
      if case .failed = state { Task { @MainActor [weak self] in self?.onSession?(.disconnected) } }
    }
    listener.start(queue: queue)
    do {
      let udp = try NWListener(using: .udp)
      udp.stateUpdateHandler = { [weak self] state in
        if case .failed = state { Task { @MainActor [weak self] in self?.onSession?(.disconnected) } }
      }
      udp.newConnectionHandler = { [weak self] newConnection in
        Task { @MainActor [weak self] in self?.acceptUDP(newConnection) }
      }
      udpListener = udp
      udp.start(queue: queue)
    } catch {
      onSession?(.disconnected)
    }
  }

  public func stop() {
    listener.cancel()
    udpListener?.cancel()
    disconnectSession(notify: sessionConnected)
  }

  private func acceptConnection(_ newConnection: NWConnection) {
    if sessionConnected {
      newConnection.start(queue: queue)
      receiveBusy(newConnection)
      return
    }
    connection?.cancel()
    connection = newConnection
    framer = ControlFramer()
    newConnection.stateUpdateHandler = { [weak self] state in
      guard case .ready = state else { return }
      Task { @MainActor [weak self] in
        guard let self, self.connection === newConnection else { return }
        // The path is available here; accept-time state does not need to guess it.
        if case .hostPort(let host, _) = newConnection.currentPath?.remoteEndpoint {
          self.session.setRemoteHost(String(describing: host))
        }
      }
    }
    newConnection.start(queue: queue)
    receiveControl(from: newConnection)
  }

  private func receiveBusy(_ connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    if busyFramers[id] == nil { busyFramers[id] = ControlFramer() }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }
        if let data, let messages = try? self.busyFramers[id, default: ControlFramer()].append(Array(data)),
          messages.contains(where: {
            if case .hello = $0 { return true }
            return false
          })
        {
          self.busyFramers[id] = nil
          connection.send(
            content: Data(ControlFramer().encode(.helloAck(.init(accepted: false, reason: "busy")))),
            completion: .contentProcessed { _ in connection.cancel() })
        } else if !complete, error == nil {
          self.receiveBusy(connection)
        } else {
          self.busyFramers[id] = nil
          connection.cancel()
        }
      }
    }
  }

  private func receiveControl(from expected: NWConnection) {
    expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self, self.connection === expected else { return }
        if let data, !data.isEmpty {
          do {
            for message in try self.framer.append(Array(data)) { await self.handle(message) }
          } catch {
            self.disconnectSession(notify: self.sessionConnected)
            return
          }
        }
        if complete || error != nil {
          self.disconnectSession(notify: self.sessionConnected)
        } else {
          self.receiveControl(from: expected)
        }
      }
    }
  }

  private func handle(_ message: ControlMessage) async {
    let now = Date.timeIntervalSinceReferenceDate
    switch message {
    case .hello(let hello):
      let decision = session.hello(
        protocolVersion: hello.protocolVersion, busy: sessionConnected, acceptResult: false, now: now)
      if case .rejected(let reason) = decision, reason != "rejected" && reason != "busy" {
        sendControl(.helloAck(.init(accepted: false, reason: reason)))
        connection?.cancel()
        connection = nil
        return
      }
      if hello.protocolVersion != PenSample.version {
        sendControl(.helloAck(.init(accepted: false, reason: "Update the iPad app to the current version.")))
        connection?.cancel()
        connection = nil
        return
      }
      if sessionConnected {
        sendControl(.helloAck(.init(accepted: false, reason: "busy")))
        connection?.cancel()
        connection = nil
        return
      }
      guard await accept(hello) else {
        sendControl(.helloAck(.init(accepted: false, reason: "rejected")))
        connection?.cancel()
        connection = nil
        return
      }
      _ = session.hello(protocolVersion: hello.protocolVersion, busy: false, acceptResult: true, now: now)
      guard let port = udpListener?.port?.rawValue else {
        sendControl(.helloAck(.init(accepted: false, reason: "UDP listener unavailable")))
        connection?.cancel()
        connection = nil
        return
      }
      sessionConnected = true
      sendControl(.helloAck(.init(accepted: true, udpPort: port, displayWidth: 0, displayHeight: 0)))
      onSession?(.connected(hello))
      startHeartbeat()
    case .geometry(let geometry):
      guard sessionConnected else { return }
      session.received(at: now)
      onSession?(.geometryChanged(geometry))
    case .ping:
      guard sessionConnected else { return }
      session.received(at: now)
      sendControl(.ping)
    case .helloAck: break
    }
  }

  private func sendControl(_ message: ControlMessage) {
    guard let connection else { return }
    connection.send(content: Data(ControlFramer().encode(message)), completion: .contentProcessed { _ in })
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        if self.session.timeoutIfNeeded(at: Date.timeIntervalSinceReferenceDate) {
          self.disconnectSession(notify: true)
          return
        }
        self.sendControl(.ping)
      }
    }
  }

  private func acceptUDP(_ udp: NWConnection) {
    guard sessionConnected else {
      udp.cancel()
      return
    }
    udp.stateUpdateHandler = { [weak self] state in
      guard case .ready = state else { return }
      Task { @MainActor [weak self] in self?.receiveUDP(udp) }
    }
    udp.start(queue: queue)
  }

  private func receiveUDP(_ udp: NWConnection) {
    udp.receiveMessage { [weak self] data, _, _, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let data, data.count == PenSample.byteCount, let sample = try? PenSample(decoding: Array(data)),
          case .hostPort(let host, _) = udp.currentPath?.remoteEndpoint,
          self.session.acceptsUDP(from: String(describing: host), sequence: sample.sequence)
        {
          self.session.received(at: Date.timeIntervalSinceReferenceDate)
          self.onSample?(sample)
        }
        if error == nil, self.sessionConnected { self.receiveUDP(udp) }
      }
    }
  }

  private func disconnectSession(notify: Bool) {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    connection?.cancel()
    connection = nil
    session.disconnect()
    sessionConnected = false
    framer = ControlFramer()
    if notify { onSession?(.disconnected) }
  }
}
