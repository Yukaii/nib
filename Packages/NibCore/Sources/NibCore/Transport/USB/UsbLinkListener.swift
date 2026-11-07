import Foundation
import Network
import os

private let usbListenerLogger = Logger(subsystem: "dev.yukai.nib", category: "usb")

/// iPad-side TCP listener used by usbmuxd. The listener is intentionally
/// loopback-only: usbmuxd forwards a cable connection through localhost.
@MainActor
public final class UsbLinkListener {
  public typealias StateHandler = @MainActor (Bool) -> Void
  public private(set) var isConnected = false
  public var stateHandler: StateHandler?
  public var onFrontApp: @MainActor (ControlMessage.FrontApp) -> Void = { _ in }
  public private(set) var hostInfo: ControlMessage.HostInfo?
  public var onHostInfo: @MainActor (ControlMessage.HostInfo?) -> Void = { _ in }
  public var onPairingEvent: ((PairingTransportEvent) -> Void)?
  private var pairingDriver: PairingDriver?
  private var deviceLink = DeviceLink()
  private var pairingStoreRef: PairingKeyStore?
  public var pairingPhase: PairingPhase? { pairingDriver?.phase }

  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "dev.yukai.nib.usb-listener")
  private var listener: NWListener?
  private var connection: NWConnection?
  private var framer = StreamFramer()
  private var hello: ControlMessage.Hello?
  private var lastTrafficAt: TimeInterval?
  private var heartbeatTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var listenerReady = false

  public init(port: UInt16 = 47811) {
    self.port = NWEndpoint.Port(rawValue: port)!
  }

  public func start(hello: ControlMessage.Hello) {
    self.hello = hello
    deviceLink.updateBaseHello(hello)
    stopListenerOnly()
    startListener()
  }

  /// iOS invalidates listening sockets while the app is suspended and the
  /// listener does not recover on its own, so the app calls this when it
  /// becomes active. An existing USB session is left alone.
  public func resumeListening() {
    guard hello != nil, !listenerReady else { return }
    startListener()
  }

  private func startListener() {
    listener?.cancel()
    listener = nil
    listenerReady = false
    retryTask?.cancel()
    retryTask = nil
    do {
      let tcp = NWProtocolTCP.Options()
      tcp.noDelay = true
      let parameters = NWParameters(tls: nil, tcp: tcp)
      parameters.allowLocalEndpointReuse = true
      let newListener = try NWListener(using: parameters, on: port)
      newListener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in self?.accept(connection) }
      }
      newListener.stateUpdateHandler = { [weak self, weak newListener] state in
        Task { @MainActor [weak self] in
          guard let self, let newListener, self.listener === newListener else { return }
          switch state {
          case .ready: self.listenerReady = true
          case .failed(let error):
            usbListenerLogger.error("USB listener failed: \(String(describing: error), privacy: .public)")
            self.listenerReady = false
            self.scheduleListenerRetry()
          case .cancelled: self.listenerReady = false
          default: break
          }
        }
      }
      newListener.start(queue: queue)
      listener = newListener
    } catch {
      usbListenerLogger.error("USB listener could not start: \(String(describing: error), privacy: .public)")
      scheduleListenerRetry()
    }
  }

  private func scheduleListenerRetry() {
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.startListener()
    }
  }

  public func stop() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    retryTask?.cancel()
    retryTask = nil
    if let id = connection.map(ObjectIdentifier.init) { pairingDriver?.connectionLost(id) }
    pairingDriver = nil
    listener?.cancel()
    listener = nil
    listenerReady = false
    connection?.cancel()
    connection = nil
    lastTrafficAt = nil
    setConnected(false)
  }

  private func stopListenerOnly() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    retryTask?.cancel()
    retryTask = nil
    if let id = connection.map(ObjectIdentifier.init) { pairingDriver?.connectionLost(id) }
    pairingDriver = nil
    listener?.cancel()
    listener = nil
    listenerReady = false
    connection?.cancel()
    connection = nil
    lastTrafficAt = nil
    setConnected(false)
  }

  // MARK: - Device-role pairing over USB (same code path as Wi-Fi)

  public func configurePairing(store: PairingKeyStore?, hostID: String?) {
    pairingStoreRef = store
    deviceLink.updateStore(store: store, hostID: hostID)
    if let base = hello { deviceLink.updateBaseHello(base) }
    if let store, hostID != nil {
      if pairingDriver == nil {
        let driver = PairingDriver(
          role: .device, localID: hello?.deviceID ?? "",
          localName: { [weak self] in
            self?.hello?.deviceName ?? "iPad"
          }, store: store)
        driver.onSend = { [weak self] message in
          guard let self, let current = self.connection,
            let bound = self.pairingDriver?.boundConnection,
            ObjectIdentifier(current) == bound
          else { return }
          self.send(message)
        }
        driver.onEvent = { [weak self] event in self?.handleDriverEvent(event) }
        pairingDriver = driver
      }
    } else {
      pairingDriver = nil
    }
  }

  private var currentConnectionID: ObjectIdentifier? {
    connection.map(ObjectIdentifier.init)
  }

  private func authenticatedHello() -> ControlMessage.Hello {
    if let base = hello {
      deviceLink.updateBaseHello(base)
    }
    return deviceLink.makeHello()
  }

  public func beginPairing(deviceID: String, deviceName: String) {
    guard let id = currentConnectionID else { return }
    pairingDriver?.beginPairing(deviceID: deviceID, deviceName: deviceName, connectionID: id)
  }

  public func confirmPairing() {
    guard let id = currentConnectionID else { return }
    pairingDriver?.confirm(connectionID: id)
  }

  public func cancelPairing() {
    guard let id = currentConnectionID else { return }
    pairingDriver?.cancel(connectionID: id)
  }

  private func handleDriverEvent(_ event: PairingTransportEvent) {
    switch event {
    case .paired(let peerID):
      deviceLink.updateStore(store: pairingStoreRef, hostID: peerID)
      onPairingEvent?(.paired(peerID: peerID))
      send(.hello(authenticatedHello()))
    case .showCode(let code, let peerName):
      onPairingEvent?(.showCode(code, peerName: peerName))
    case .cancelled:
      onPairingEvent?(.cancelled)
    case .timedOut:
      onPairingEvent?(.timedOut)
    case .failed(let reason):
      onPairingEvent?(.failed(reason))
    }
  }

  private func handlePairingMessage(_ message: ControlMessage) {
    guard let id = currentConnectionID else { return }
    pairingDriver?.receive(message, connectionID: id)
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
    // A new connection never inherits pairing in progress.
    pairingDriver?.newConnection(ObjectIdentifier(newConnection))
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
        self.send(.hello(self.authenticatedHello()))
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
                let outcome = self.deviceLink.receiveHelloAck(ack)
                switch outcome {
                case .invalidProof:
                  self.setConnected(false)
                case .pairingRequired(let reason, let info):
                  self.hostInfo = info
                  self.onHostInfo(info)
                  _ = reason
                  self.setConnected(false)
                // Keep the connection open for pairing; beginPairing sends
                // pairRequest on this same connection.
                case .rejected(_, _, _):
                  // Unauthenticated rejection: show it via disconnected state
                  // but never delete a stored key on its basis.
                  self.setConnected(false)
                case .connected(let info):
                  self.hostInfo = info
                  self.onHostInfo(info)
                  self.setConnected(true)
                  if self.isConnected { self.startHeartbeat() }
                }
              case .probe(let sentAtNs): self.send(.probeReply(sentAtNs: sentAtNs))
              case .frontApp(let app): self.onFrontApp(app)
              case .pairResponse, .pairResult:
                self.handlePairingMessage(message)
              case .pairRequest, .pairReveal, .hello, .geometry, .ping, .probeReply, .gesture:
                break
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
    if let id = currentConnectionID { pairingDriver?.connectionLost(id) }
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
