import Foundation
import Network
import os

private let usbListenerLogger = Logger(subsystem: "dev.yukai.nib", category: "usb")

public enum USBPairingTransport: Sendable, Equatable {
  case wifi, usb

  public static func choose(usbHasLiveConnection: Bool) -> Self {
    usbHasLiveConnection ? .usb : .wifi
  }
}

/// iPad-side TCP listener used by usbmuxd. The listener is intentionally
/// loopback-only: usbmuxd forwards a cable connection through localhost.
@MainActor
public final class UsbLinkListener {
  public typealias StateHandler = @MainActor (Bool) -> Void
  public private(set) var isConnected = false
  /// True while the USB stream is live, including an unauthenticated
  /// pairing-only connection.
  public var hasLiveConnection: Bool { connection != nil }
  public var stateHandler: StateHandler?
  public var onFrontApp: @MainActor (ControlMessage.FrontApp) -> Void = { _ in }
  public private(set) var hostInfo: ControlMessage.HostInfo?
  public var onHostInfo: @MainActor (ControlMessage.HostInfo?) -> Void = { _ in }
  public var onPairingEvent: ((PairingTransportEvent) -> Void)?
  private var pairingDriver: PairingDriver?
  private var deviceLink = DeviceLink()
  private var pairingStoreRef: PairingKeyStore?
  private var pairingRequested = false
  public var pairingPhase: PairingPhase? { pairingDriver?.phase }
  /// Whether pairing is configured; tests check it survives stop/start.
  public var canPair: Bool { pairingDriver != nil }

  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "dev.yukai.nib.usb-listener")
  private var listener: NWListener?
  private var connection: NWConnection?
  private var connectionGeneration: UInt64 = 0
  private var streamDispatcher: StreamLinkDispatcher?
  private let sessionCipher = LockedSessionCipher()
  private var hello: ControlMessage.Hello?
  private var lastTrafficAt: TimeInterval?
  private var awaitingAuthenticatedAck = false
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
    pairingRequested = false
    retryTask?.cancel()
    retryTask = nil
    // The driver is configuration (set by configurePairing), not socket
    // state: end its connection but keep it. Clearing it here meant start()
    // threw away the driver configured just before, so USB could never pair.
    pairingDriver?.connectionLost(connectionGeneration)
    deviceLink.connectionLost()
    sessionCipher.set(nil)
    awaitingAuthenticatedAck = false
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
    // The driver is configuration (set by configurePairing), not socket
    // state: end its connection but keep it. Clearing it here meant start()
    // threw away the driver configured just before, so USB could never pair.
    pairingDriver?.connectionLost(connectionGeneration)
    deviceLink.connectionLost()
    sessionCipher.set(nil)
    awaitingAuthenticatedAck = false
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
          guard let self, self.connection != nil,
            self.pairingDriver?.boundGeneration == self.connectionGeneration
          else {
            usbListenerLogger.info("pairing send dropped=unbound")
            return
          }
          if case .pairRequest = message { usbListenerLogger.info("pairing send message=pairRequest") }
          self.send(message)
        }
        driver.onSendUnbound = { [weak self] message, generation in
          guard let self, self.connection != nil, self.connectionGeneration == generation else { return }
          self.send(message)
        }
        driver.onEvent = { [weak self] event in self?.handleDriverEvent(event) }
        pairingDriver = driver
      }
    } else {
      pairingDriver = nil
    }
  }

  private func authenticatedHello() -> ControlMessage.Hello {
    if let base = hello {
      deviceLink.updateBaseHello(base)
    }
    return deviceLink.makeHello()
  }

  public func beginPairing(deviceID: String, deviceName: String) {
    if deviceLink.pairingRequired && deviceLink.requiresAuthentication {
      usbListenerLogger.info("pairing begin branch=stale-key-pair-again")
      pairAgain()
      return
    }
    guard connection != nil else {
      usbListenerLogger.info("pairing begin branch=deferred-no-connection")
      pairingRequested = true
      return
    }
    pairingRequested = false
    let hasDriver = pairingDriver != nil
    let phase = pairingDriver?.phase.map { "\($0)".prefix(while: { $0 != "(" }) } ?? "none"
    usbListenerLogger.info(
      "pairing begin branch=start driver=\(hasDriver, privacy: .public) machine=\(String(phase), privacy: .public) gen=\(self.connectionGeneration, privacy: .public)"
    )
    pairingDriver?.beginPairing(
      deviceID: deviceID, deviceName: deviceName, connectionGeneration: connectionGeneration)
  }

  /// Explicitly forgets the held key after the user chooses to pair again.
  public func pairAgain() {
    guard let store = pairingStoreRef, let hostID = deviceLink.knownHostID else {
      usbListenerLogger.info("pairing again skipped=no-store-or-host")
      return
    }
    usbListenerLogger.info("pairing again drop=\(self.connection != nil, privacy: .public)")
    store.removeKey(for: hostID)
    deviceLink.updateStore(store: store, hostID: hostID)
    pairingRequested = true
    if let connection { drop(connection) }
  }

  public func confirmPairing() {
    guard connection != nil else { return }
    pairingDriver?.confirm(connectionGeneration: connectionGeneration)
  }

  public func cancelPairing() {
    guard connection != nil else { return }
    pairingDriver?.cancel(connectionGeneration: connectionGeneration)
  }

  private func handleDriverEvent(_ event: PairingTransportEvent) {
    let phase: String
    switch event {
    case .showCode: phase = "show-code"
    case .pairingRequired: phase = "required"
    case .paired: phase = "paired"
    case .cancelled: phase = "cancelled"
    case .timedOut: phase = "timed-out"
    case .failed: phase = "failed"
    }
    usbListenerLogger.info("pairing phase=\(phase, privacy: .public)")
    switch event {
    case .paired(let peerID):
      deviceLink.updateStore(store: pairingStoreRef, hostID: peerID)
      onPairingEvent?(.paired(peerID: peerID))
      awaitingAuthenticatedAck = deviceLink.requiresAuthentication
      send(.hello(authenticatedHello()))
    case .showCode(let code, let peerName):
      onPairingEvent?(.showCode(code, peerName: peerName))
    case .pairingRequired(let peerName):
      onPairingEvent?(.pairingRequired(peerName: peerName))
    case .cancelled:
      onPairingEvent?(.cancelled)
    case .timedOut:
      onPairingEvent?(.timedOut)
    case .failed(let reason):
      onPairingEvent?(.failed(reason))
    }
  }

  private func handlePairingMessage(_ message: ControlMessage) {
    guard connection != nil else { return }
    pairingDriver?.receive(message, connectionGeneration: connectionGeneration)
  }

  public func send(_ sample: PenSample) {
    guard isConnected else { return }
    streamDispatcher?.send(sample)
  }

  public func send(_ message: ControlMessage) {
    if awaitingAuthenticatedAck {
      guard case .hello = message else { return }
    }
    streamDispatcher?.send(message)
  }

  private func accept(_ newConnection: NWConnection) {
    // Only the Mac on the cable reaches this loopback listener, so a new
    // connection means the old one is gone (e.g. replugged), even mid-pairing:
    // replace it and let pairing restart. Refusing here kept a dead pairing
    // alive and looped the Mac's reconnects.
    // A new connection never inherits pairing in progress.
    pairingDriver?.connectionLost(connectionGeneration)
    deviceLink.connectionLost()
    connectionGeneration &+= 1
    pairingDriver?.newConnection(connectionGeneration)
    connection?.cancel()
    connection = newConnection
    usbListenerLogger.info("connection accept reason=usb")
    let generation = connectionGeneration
    let arm = deviceLink.sessionArm
    let sharedCipher = sessionCipher
    streamDispatcher = StreamLinkDispatcher(
      transport: NWLinkByteTransport(newConnection),
      armSession: { message in
        guard case .helloAck(let ack) = message else { return nil }
        let cipher = arm.make(ack)
        sharedCipher.set(cipher)
        return cipher
      },
      onControl: { [weak self] message in
        Task { @MainActor [weak self] in
          guard let self, self.connectionGeneration == generation,
            self.connection === newConnection
          else { return }
          self.handle(message)
        }
      },
      onSample: { _ in },
      onCloseReason: { reason in
        usbListenerLogger.info("connection close transport=usb reason=\(reason, privacy: .public)")
      })
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
            try self.streamDispatcher?.receive(data)
          } catch {
            self.drop(expected)
            return
          }
        }
        if complete || error != nil { self.drop(expected) } else { self.receive(from: expected) }
      }
    }
  }

  private func handle(_ message: ControlMessage) {
    guard deviceLink.allows(message) else { return }
    switch message {
    case .helloAck(let ack):
      awaitingAuthenticatedAck = false
      let outcome = deviceLink.receiveHelloAck(ack)
      switch outcome {
      case .invalidProof:
        setConnected(false)
        if let connection { drop(connection, reason: "auth-failure") }
      case .pairingRequired(let reason, let info):
        if let info {
          hostInfo = info
          onHostInfo(info)
        }
        setConnected(false)
        onPairingEvent?(.pairingRequired(peerName: hostInfo?.name ?? info?.name ?? "Mac"))
        if pairingRequested {
          beginPairing(deviceID: hello?.deviceID ?? "", deviceName: hello?.deviceName ?? "iPad")
        }
        usbListenerLogger.info("pairing required: \(String(reason.prefix(200)), privacy: .private)")
      case .rejected(let reason, let info, _):
        if let info {
          hostInfo = info
          onHostInfo(info)
        }
        setConnected(false)
        usbListenerLogger.info("session rejected: \(String(reason.prefix(200)), privacy: .private)")
      case .connected(let info):
        hostInfo = info
        onHostInfo(info)
        if deviceLink.requiresAuthentication {
          guard sessionCipher.get() != nil else {
            if let connection { drop(connection, reason: "auth-failure") }
            return
          }
        } else {
          sessionCipher.set(nil)
          streamDispatcher?.clearSession()
        }
        setConnected(true)
        if isConnected { startHeartbeat() }
      }
    case .probe(let sentAtNs): send(.probeReply(sentAtNs: sentAtNs))
    case .frontApp(let app): onFrontApp(app)
    case .pairResponse, .pairResult: handlePairingMessage(message)
    case .pairRequest, .pairReveal, .hello, .geometry, .ping, .probeReply, .gesture: break
    }
  }

  private func drop(_ expected: NWConnection, reason: String = "peer-eof") {
    guard connection === expected else { return }
    pairingDriver?.connectionLost(connectionGeneration)
    deviceLink.connectionLost()
    sessionCipher.set(nil)
    expected.cancel()
    usbListenerLogger.info("connection close transport=usb reason=\(reason, privacy: .public)")
    connection = nil
    streamDispatcher = nil
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
          if let connection = self.connection { self.drop(connection, reason: "heartbeat-timeout") }
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
