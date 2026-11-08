import Foundation
import Network
import os

private let transportLogger = Logger(subsystem: "dev.yukai.nib", category: "transport")

/// Lock-backed state shared by the Network callback queue and the main actor.
/// The lock protects the entire value so UDP admission and sequence checks are atomic.
private final class UDPGate: @unchecked Sendable {
  private let lock = NSLock()
  private var host: String?
  private var accepted = false
  private var sequencer = SampleSequencer()
  func configure(host: String?) {
    lock.lock()
    self.host = host
    accepted = host != nil
    sequencer.reset()
    lock.unlock()
  }
  func disable() {
    lock.lock()
    accepted = false
    host = nil
    sequencer.reset()
    lock.unlock()
  }
  func accepts(host incoming: String, sequence: UInt32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard accepted, host == incoming else { return false }
    return sequencer.accept(
      .init(kind: .move, sequence: sequence, timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0))
  }
}

/// LinkStats is kept off the main actor without sorting on the datagram path.
private final class LockedStats: @unchecked Sendable {
  private let lock = NSLock()
  private var value = LinkStats()
  func reset() {
    lock.lock()
    value = LinkStats()
    lock.unlock()
  }
  func record(sequence: UInt32, sender: UInt64, arrival: UInt64) {
    lock.lock()
    value.record(sequence: sequence, senderTimestampNs: sender, arrivalNs: arrival)
    lock.unlock()
  }
  func snapshot(nowNs: UInt64) -> LinkStats.Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return value.snapshot(nowNs: nowNs)
  }
}

/// Timestamp publication crosses the Network queue and the heartbeat task under this lock.
private final class LockedTimestamp: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval?
  func set(_ value: TimeInterval?) {
    lock.lock()
    self.value = value
    lock.unlock()
  }
  func get() -> TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Thread-safe gate for USB samples: only the accepted session may inject.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set(_ value: Bool) {
    lock.lock()
    self.value = value
    lock.unlock()
  }
  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class SampleSink: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: ((PenSample, UInt64) -> Void)?
  func set(_ handler: ((PenSample, UInt64) -> Void)?) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }
  func send(_ sample: PenSample, arrivalNs: UInt64) {
    lock.lock()
    let handler = self.handler
    lock.unlock()
    handler?(sample, arrivalNs)
  }
}

#if os(macOS)
  private final class USBConnectionIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ObjectIdentifier?

    func set(_ connection: NWConnection?) {
      lock.lock()
      value = connection.map(ObjectIdentifier.init)
      lock.unlock()
    }

    func matches(_ connection: NWConnection) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return value == ObjectIdentifier(connection)
    }
  }
#endif

public enum PenLinkState: Sendable, Equatable {
  case searching, connecting
  case connected(name: String, viaUSB: Bool)
  case rejected(String)

  public func userFacingText(selectedHost: String? = nil) -> String {
    switch self {
    case .searching:
      return selectedHost.map { "Looking for \($0)…" } ?? "Looking for your Mac…"
    case .connecting: return "Connecting to your Mac…"
    case .connected(_, true): return "Connected by cable"
    case .connected(let name, false): return "Connected to \(name)"
    case .rejected(let reason): return reason
    }
  }
}

public enum PenLinkSessionEvent: Sendable, Equatable {
  case connected(ControlMessage.Hello)
  case geometryChanged(ControlMessage.Geometry)
  case disconnected
}

public enum PenLinkRejectionDecision: Sendable, Equatable {
  case retryLater, final
}

public enum PenLinkRejectionPolicy {
  public static func decision(reason: String?) -> PenLinkRejectionDecision {
    reason == "busy" ? .retryLater : .final
  }
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
  private var pairingKey: Data?
  private var hostID: String?

  public init(pairingKey: Data? = nil, hostID: String? = nil) {
    self.pairingKey = pairingKey
    self.hostID = hostID
  }

  /// Refreshes the key used for the current hello. The receiver calls this
  /// with the stored key for `hello.deviceID` before verifying, so one
  /// session object serves any number of paired iPads over time.
  public mutating func updatePairingKey(_ key: Data?, hostID: String?) {
    pairingKey = key
    self.hostID = hostID
  }

  public var requiresPairingAuthentication: Bool { pairingKey != nil }

  public func verifiesPairingProof(_ hello: ControlMessage.Hello) -> Bool {
    guard let pairingKey, let nonce = hello.nonce, let proof = hello.proof else { return false }
    return PairingCrypto.verifyHelloProof(
      base64Proof: proof, pairKey: pairingKey, identifier: hello.deviceID, base64Nonce: nonce)
  }

  public func authenticatedHelloAck(
    deviceNonce: Data, hostNonce: Data, accepted: Bool = true, reason: String? = nil,
    udpPort: UInt16 = 0, displayWidth: Double = 0, displayHeight: Double = 0,
    host: ControlMessage.HostInfo? = nil
  ) -> ControlMessage.HelloAck {
    guard accepted, let pairingKey, let hostID else {
      return .init(
        accepted: accepted, reason: reason, udpPort: udpPort, displayWidth: displayWidth,
        displayHeight: displayHeight, host: host)
    }
    return .init(
      accepted: true, reason: nil, udpPort: udpPort, displayWidth: displayWidth,
      displayHeight: displayHeight, host: host,
      nonce: PairingCrypto.base64(hostNonce),
      proof: PairingCrypto.base64(
        PairingCrypto.hostProof(
          pairKey: pairingKey, hostID: hostID, deviceNonce: deviceNonce, hostNonce: hostNonce)))
  }

  public static func versionMismatchReason(remoteProtocol: UInt8, hostAppVersion: String) -> String {
    let update =
      remoteProtocol < ControlMessage.ProtocolVersion.control
      ? "Update Nib on your iPad" : "Update Nib on your Mac"
    return
      "This Mac runs Nib \(hostAppVersion) (protocol \(ControlMessage.ProtocolVersion.control)). \(update)."
  }

  public mutating func hello(
    protocolVersion: UInt8, busy: Bool, acceptResult: Bool, now: TimeInterval,
    hostAppVersion: String = "unknown"
  ) -> HelloDecision {
    guard !busy else { return .rejected("busy") }
    guard protocolVersion == ControlMessage.ProtocolVersion.control else {
      return .rejected(
        Self.versionMismatchReason(remoteProtocol: protocolVersion, hostAppVersion: hostAppVersion))
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
  public typealias HostsHandler = @MainActor ([String]) -> Void
  public private(set) var state: PenLinkState = .searching {
    didSet {
      transportLogger.info("sender state: \(String(describing: self.state), privacy: .public)")
      stateHandler?(self.state)
    }
  }
  public var stateHandler: StateHandler?
  public var hostsHandler: HostsHandler?
  public var onFrontApp: @MainActor (ControlMessage.FrontApp) -> Void = { _ in }
  public private(set) var hostInfo: ControlMessage.HostInfo?
  /// True while the Wi-Fi control stream is live, including pairing-only.
  public var hasLiveConnection: Bool { connection != nil }
  public var onHostInfo: @MainActor (ControlMessage.HostInfo?) -> Void = { _ in }
  public var onPairingEvent: ((PairingTransportEvent) -> Void)?
  private var pairingDriver: PairingDriver?
  private var deviceLink = DeviceLink()
  private var pairingStoreRef: PairingKeyStore?
  private var pairingRequested = false
  public var pairingPhase: PairingPhase? { pairingDriver?.phase }

  private var browser: NWBrowser?
  private var latestResult: NWBrowser.Result?
  private var resultsByName: [String: NWBrowser.Result] = [:]
  public private(set) var discoveredHosts: [String] = [] {
    didSet { hostsHandler?(discoveredHosts) }
  }
  public private(set) var selectedHost: String?
  private var connection: NWConnection?
  private var connectionGeneration: UInt64 = 0
  private var udpConnection: NWConnection?
  private var framer = ControlFramer()
  private var controlDispatcher: ControlLinkDispatcher?
  private var hello: ControlMessage.Hello?
  private var lastReceivedAt: TimeInterval?
  private var lastGeometry: (Double, Double)?
  private var reconnectTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private let queue = DispatchQueue(label: "dev.yukai.nib.sender")

  public init() {}

  public func start(hello: ControlMessage.Hello, rememberedHost: String? = nil) {
    self.hello = hello
    deviceLink.updateBaseHello(hello)
    selectedHost = rememberedHost
    startBrowser()
  }

  /// Selects a Bonjour service by its user-visible Mac name. Passing nil clears
  /// the choice and returns to the explicit selection state when several Macs exist.
  public func selectHost(_ name: String?) {
    selectedHost = name
    connectionLost(reconnect: false)
    state = .searching
    connectToBestResult()
  }

  public func stop() {
    reconnectTask?.cancel()
    reconnectTask = nil
    pairingRequested = false
    pingTask?.cancel()
    pingTask = nil
    pairingDriver?.connectionLost(connectionGeneration)
    deviceLink.connectionLost()
    pairingDriver = nil
    browser?.cancel()
    browser = nil
    connection?.cancel()
    udpConnection?.cancel()
    connection = nil
    controlDispatcher = nil
    udpConnection = nil
    latestResult = nil
    resultsByName = [:]
    discoveredHosts = []
    lastReceivedAt = nil
    state = .searching
  }

  // MARK: - Device-role pairing (NibCore only; UI lives in the apps)

  /// Opts the sender into authenticated hello + pairing. With nil store the
  /// sender keeps today's behaviour (no proofs, no pairing).
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
          else { return }
          self.sendControl(message)
        }
        driver.onSendUnbound = { [weak self] message, generation in
          guard let self, self.connection != nil, self.connectionGeneration == generation else { return }
          self.sendControl(message)
        }
        driver.onEvent = { [weak self] event in self?.handleDriverEvent(event) }
        pairingDriver = driver
      } else {
        pairingDriver?.updateLocal(
          id: hello?.deviceID ?? "",
          name: { [weak self] in self?.hello?.deviceName ?? "iPad" })
      }
    } else {
      pairingDriver = nil
    }
  }

  public func beginPairing(deviceID: String, deviceName: String) {
    // A host that no longer has our key invited a re-pair on this connection.
    // Drop the stale authenticated session before sending pairing traffic.
    if deviceLink.pairingRequired && deviceLink.requiresAuthentication {
      pairAgain()
      return
    }
    guard let driver = pairingDriver else { return }
    guard connection != nil else {
      pairingRequested = true
      scheduleReconnect()
      return
    }
    pairingRequested = false
    driver.beginPairing(
      deviceID: deviceID, deviceName: deviceName, connectionGeneration: connectionGeneration)
  }

  /// Explicitly forgets a held key, then starts pairing on the current link.
  public func pairAgain() {
    guard let store = pairingStoreRef, let hostID = deviceLink.knownHostID else { return }
    store.removeKey(for: hostID)
    deviceLink.updateStore(store: store, hostID: hostID)
    pairingRequested = true
    connectionLost()
  }

  public func confirmPairing() {
    guard connection != nil else { return }
    pairingDriver?.confirm(connectionGeneration: connectionGeneration)
  }

  public func cancelPairing() {
    guard connection != nil else { return }
    pairingDriver?.cancel(connectionGeneration: connectionGeneration)
  }

  private func handlePairingMessage(_ message: ControlMessage) {
    guard connection != nil else { return }
    pairingDriver?.receive(message, connectionGeneration: connectionGeneration)
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
    transportLogger.info("pairing phase=\(phase, privacy: .public)")
    switch event {
    case .paired(let peerID):
      // Fresh authenticated hello on the same connection.
      deviceLink.updateStore(store: pairingStoreRef, hostID: peerID)
      onPairingEvent?(.paired(peerID: peerID))
      sendControl(.hello(authenticatedHello()))
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
    if let base = hello { deviceLink.updateBaseHello(base) }
    guard connection != nil, case .connected = state else { return }
    sendControl(.geometry(.init(surfaceWidth: width, surfaceHeight: height)))
  }

  public func ping() { sendControl(.ping) }

  public func send(_ gesture: Gesture) { sendControl(.gesture(gesture)) }
  public func send(_ message: ControlMessage) { sendControl(message) }

  private func startBrowser() {
    browser?.cancel()
    let newBrowser = NWBrowser(for: .bonjour(type: "_nib._tcp", domain: nil), using: .tcp)
    browser = newBrowser
    newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let named = results.compactMap { result -> (String, NWBrowser.Result)? in
          guard case .service(let name, _, _, _) = result.endpoint else { return nil }
          return (name, result)
        }
        let unique = MacSelectionPolicy.deduplicated(named)
        self.resultsByName = unique.reduce(into: [:]) { $0[$1.0] = $1.1 }
        self.discoveredHosts = unique.map(\.0).sorted()
        self.latestResult = unique.first(where: { $0.0 == self.selectedHost })?.1
        self.connectToBestResult(results: unique)
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

  private func connectToBestResult(results: [(String, NWBrowser.Result)]? = nil) {
    let named = results ?? discoveredHosts.compactMap { name in resultsByName[name].map { (name, $0) } }
    let choice = MacSelectionPolicy.choose(remembered: selectedHost, results: named.map(\.0))
    let name: String
    switch choice {
    case .remembered(let remembered): name = remembered
    case .single(let single): name = single
    case .ask:
      // A browse update can temporarily contain several interfaces while a
      // session is already working. Keep the live session and its status.
      guard
        !MacSelectionPolicy.shouldPreserveLiveConnection(
          hasConnection: connection != nil, choice: choice)
      else { return }
      state = .searching
      return
    }
    guard let result = named.first(where: { $0.0 == name })?.1 else { return }
    latestResult = result
    if case .single(let single) = choice {
      selectedHost = single
      UserDefaults.standard.set(single, forKey: "nib.selectedMac")
    }
    connect(to: result)
  }

  private func connect(to result: NWBrowser.Result?) {
    guard connection == nil, let result else { return }
    guard case .service(let name, let type, let domain, let interface) = result.endpoint else { return }
    state = .connecting
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let tcpParameters = NWParameters(tls: nil, tcp: tcpOptions)
    let newConnection = NWConnection(
      to: .service(name: name, type: type, domain: domain, interface: interface), using: tcpParameters)
    connection = newConnection
    transportLogger.info("connection accept transport=wifi reason=selected-host")
    connectionGeneration &+= 1
    pairingDriver?.newConnection(connectionGeneration)
    framer = ControlFramer()
    let generation = connectionGeneration
    controlDispatcher = ControlLinkDispatcher(transport: NWLinkByteTransport(newConnection)) {
      [weak self] message in
      Task { @MainActor [weak self] in self?.handle(message, connectionGeneration: generation) }
    }
    newConnection.stateUpdateHandler = { [weak self] newState in
      if case .failed = newState {
        Task { @MainActor [weak self] in self?.connectionLost() }
      }
    }
    newConnection.start(queue: queue)
    receiveControl(from: newConnection)
    sendControl(.hello(authenticatedHello()))
  }

  private func authenticatedHello() -> ControlMessage.Hello {
    if let base = hello {
      deviceLink.updateBaseHello(base)
    }
    return deviceLink.makeHello()
  }

  private func receiveControl(from expected: NWConnection) {
    expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      Task { @MainActor [weak self] in
        guard let self, self.connection === expected else { return }
        if let data, !data.isEmpty {
          self.lastReceivedAt = Date.timeIntervalSinceReferenceDate
          do {
            try self.controlDispatcher?.receive(data)
          } catch {
            self.connectionLost()
            return
          }
        }
        if isComplete || error != nil { self.connectionLost() } else { self.receiveControl(from: expected) }
      }
    }
  }

  private func handle(_ message: ControlMessage, connectionGeneration generation: UInt64) {
    guard self.connectionGeneration == generation else { return }
    lastReceivedAt = Date.timeIntervalSinceReferenceDate
    if !deviceLink.allows(message) { return }
    switch message {
    case .helloAck(let ack):
      // Verify before trusting hostInfo or the reason when a key is held.
      // An unauthenticated rejection is shown but never deletes a stored key.
      let outcome = deviceLink.receiveHelloAck(ack)
      switch outcome {
      case .invalidProof:
        state = .rejected("Pair again")
        connectionLost(reconnect: false)
        return
      case .pairingRequired(let reason, let info):
        if let info {
          hostInfo = info
          onHostInfo(info)
        }
        state = .searching
        transportLogger.info("pairing required: \(String(reason.prefix(200)), privacy: .private)")
        onPairingEvent?(.pairingRequired(peerName: self.hostInfo?.name ?? info?.name ?? "Mac"))
        // Keep the connection open in a pairing-only state. A retry requested
        // before reconnect is started automatically on this fresh link.
        if pairingRequested {
          beginPairing(deviceID: hello?.deviceID ?? "", deviceName: hello?.deviceName ?? "iPad")
        }
        return
      case .rejected(let reason, let info, let retryLater):
        if info != nil {
          hostInfo = info
          onHostInfo(info)
        }
        transportLogger.info("session rejected: \(String(reason.prefix(200)), privacy: .private)")
        if retryLater {
          connectionLost(reconnectDelay: .seconds(2))
        } else {
          state = .rejected(reason)
          connectionLost(reconnect: false)
        }
        return
      case .connected(let info):
        hostInfo = info
        onHostInfo(info)
        guard connection != nil else {
          connectionLost()
          return
        }
      }
      guard let connection,
        let remote = connection.currentPath?.remoteEndpoint,
        case .hostPort(let host, _) = remote,
        let port = NWEndpoint.Port(rawValue: ack.udpPort)
      else {
        connectionLost()
        return
      }
      udpConnection?.cancel()
      let udpParameters = NWParameters.udp
      udpParameters.serviceClass = .interactiveVoice
      let udp = NWConnection(to: .hostPort(host: host, port: port), using: udpParameters)
      udpConnection = udp
      udp.start(queue: queue)
      let name: String
      if case .service(let serviceName, _, _, _) = latestResult?.endpoint {
        name = serviceName
      } else {
        name = "Mac"
      }
      state = .connected(name: name, viaUSB: false)
      startHeartbeat()
    case .probe(let sentAtNs):
      sendControl(.probeReply(sentAtNs: sentAtNs))
    case .probeReply: break
    case .frontApp(let frontApp): onFrontApp(frontApp)
    case .pairResponse, .pairResult:
      handlePairingMessage(message)
    case .pairRequest, .pairReveal, .hello, .geometry, .ping, .gesture:
      break
    // Pings are never echoed: both sides send their own every second, and
    // echoing would make each one ping-pong forever.
    }
  }

  public func sendControl(_ message: ControlMessage) {
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

  private func connectionLost(reconnect: Bool = true, reconnectDelay: Duration? = nil) {
    if connection != nil { transportLogger.info("connection close transport=wifi reason=ended") }
    pairingDriver?.connectionLost(connectionGeneration)
    deviceLink.connectionLost()
    connection?.cancel()
    udpConnection?.cancel()
    connection = nil
    udpConnection = nil
    lastReceivedAt = nil
    pingTask?.cancel()
    pingTask = nil
    guard reconnect else { return }
    scheduleReconnect(after: reconnectDelay ?? .seconds(1))
  }

  private func scheduleReconnect(after delay: Duration = .seconds(1)) {
    guard reconnectTask == nil else { return }
    state = .searching
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
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
  public typealias SampleHandler = @Sendable (PenSample, UInt64) -> Void
  public typealias GestureHandler = @Sendable (Gesture) -> Void
  public typealias SessionHandler = @MainActor (PenLinkSessionEvent) -> Void
  public var accept: AcceptHandler
  public var onSample: SampleHandler? {
    didSet { sampleSink.set(onSample) }
  }
  public var onSession: SessionHandler?
  public var onGesture: GestureHandler?
  /// Display size sent in the hello acknowledgement, in points.
  public var displayWidth: Double = 0
  public var displayHeight: Double = 0
  /// Host metadata advertised to the iPad during the handshake.
  public var hostInfo: ControlMessage.HostInfo?

  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.yukai.nib.receiver")
  private var connection: NWConnection?
  private var connectionGeneration: UInt64 = 0
  #if os(macOS)
    private var usbClient: UsbmuxClient?
    private var usbDevice: UsbmuxClient.Device?
    private var usbConnection: NWConnection?
    private let usbConnectionIdentity = USBConnectionIdentity()
    private var usbDispatcher: StreamLinkDispatcher?
    private var usbMode = false
  #endif
  private var udpListener: NWListener?
  private var framer = ControlFramer()
  private var controlDispatcher: ControlLinkDispatcher?
  private var hostLink: HostLink
  private var pairingDriver: PairingDriver?
  private var pairingStoreRef: PairingKeyStore?
  private var pairingHostIDRef: String?
  private var heartbeatTask: Task<Void, Never>?
  private let udpGate = UDPGate()
  private let lockedStats = LockedStats()
  private let sampleSink = SampleSink()
  private let lastPacketAt = LockedTimestamp()
  // Closed while a USB connection is pairing-only, so unauthenticated samples
  // are never injected. One uncontended lock per sample (~20 ns against a
  // ~4 ms sample interval); `Atomic` would need macOS 15.
  private let sampleGate = LockedFlag()
  private var linkStats = LinkStats()
  private var rttSamples: [Double] = []
  public private(set) var latestRTTMs: Double?
  public private(set) var transportIsUSB = false
  public var onPairingEvent: ((PairingTransportEvent) -> Void)?
  public var pairingPhase: PairingPhase? { pairingDriver?.phase }

  public init(
    pairingKey: Data? = nil, hostID: String? = nil,
    accept: @escaping AcceptHandler = { _ in true }
  ) throws {
    self.accept = accept
    pairingStoreRef = nil
    pairingHostIDRef = hostID
    hostLink = HostLink(store: nil, hostID: hostID, fallbackKey: pairingKey)
    pairingDriver = nil
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let tcpParameters = NWParameters(tls: nil, tcp: tcpOptions)
    listener = try NWListener(using: tcpParameters)
    listener.service = NWListener.Service(type: "_nib._tcp")
    listener.newConnectionHandler = { [weak self] newConnection in
      Task { @MainActor [weak self] in self?.acceptConnection(newConnection) }
    }
  }

  /// Store-backed init for the apps: the key is looked up by deviceID on
  /// every hello, so any number of paired iPads are accepted one at a time.
  public init(
    pairingStore: PairingKeyStore, hostID: String,
    accept: @escaping AcceptHandler = { _ in true }
  ) throws {
    self.accept = accept
    pairingStoreRef = pairingStore
    pairingHostIDRef = hostID
    hostLink = HostLink(store: pairingStore, hostID: hostID)
    pairingDriver = nil
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let tcpParameters = NWParameters(tls: nil, tcp: tcpOptions)
    listener = try NWListener(using: tcpParameters)
    listener.service = NWListener.Service(type: "_nib._tcp")
    listener.newConnectionHandler = { [weak self] newConnection in
      Task { @MainActor [weak self] in self?.acceptConnection(newConnection) }
    }
    let driver = PairingDriver(
      role: .host, localID: hostID,
      localName: { [weak self] in
        self?.hostInfo?.name ?? "Mac"
      }, store: pairingStore)
    driver.onSend = { [weak self] message in
      guard let self, let current = self.connection,
        self.pairingDriver?.boundGeneration == self.connectionGeneration,
        current === self.connection
      else { return }
      self.sendControl(message)
    }
    driver.onSendUnbound = { [weak self] message, generation in
      guard let self, self.connection != nil, self.connectionGeneration == generation else { return }
      self.sendControl(message)
    }
    driver.onEvent = { [weak self] event in self?.handleDriverEvent(event) }
    pairingDriver = driver
  }

  // MARK: - Host-role pairing (NibCore only; UI lives in the apps)

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
    transportLogger.info("pairing phase=\(phase, privacy: .public)")
    // After pairing the iPad sends a fresh authenticated hello on the same
    // connection; the host clears pairing-only then and accepts it.
    switch event {
    case .paired(let peerID):
      hostLink.clearPairingOnly(connectionGeneration)
      onPairingEvent?(.paired(peerID: peerID))
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
    // In pairing-only only pair*/ping are processed; full sessions ignore
    // stray pairing traffic.
    if hostLink.sessionConnected { return }
    if !hostLink.allows(message, connectionGeneration: connectionGeneration) { return }
    pairingDriver?.receive(message, connectionGeneration: connectionGeneration)
  }

  public func start() {
    listener.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state {
        transportLogger.error("receiver listener failed: \(String(describing: error), privacy: .public)")
        Task { @MainActor [weak self] in self?.onSession?(.disconnected) }
      }
    }
    listener.start(queue: queue)
    #if os(macOS)
      let client = UsbmuxClient()
      client.onDeviceConnection = { [weak self] device, connection in
        self?.acceptUSBConnection(device: device, connection: connection)
      }
      usbClient = client
      client.start()
    #endif
    do {
      let udpParameters = NWParameters.udp
      udpParameters.serviceClass = .interactiveVoice
      let udp = try NWListener(using: udpParameters)
      udp.stateUpdateHandler = { [weak self] state in
        if case .failed(let error) = state {
          transportLogger.error(
            "receiver UDP listener failed: \(String(describing: error), privacy: .public)")
          Task { @MainActor [weak self] in self?.onSession?(.disconnected) }
        }
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

  /// Computed on demand (percentiles sort the window); never per sample.
  public func linkStatsSnapshot(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> LinkStats.Snapshot {
    lockedStats.snapshot(nowNs: nowNs)
  }

  public func stop() {
    listener.cancel()
    udpListener?.cancel()
    pairingDriver?.connectionLost(connectionGeneration)
    hostLink.connectionLost(connectionGeneration)
    pairingDriver = nil
    disconnectSession(notify: hostLink.sessionConnected)
    #if os(macOS)
      usbClient?.stop()
      usbClient = nil
    #endif
  }

  #if os(macOS)
    private var transportState: USBTransportState {
      if connection == nil { return .none }
      if usbMode {
        if hostLink.sessionConnected { return .usbSession }
        if hostLink.pairingOnlyGeneration != nil {
          return .usbPairingOnly
        }
        return .usbPending
      }
      if hostLink.sessionConnected { return .wifiSession }
      if hostLink.pairingOnlyGeneration != nil {
        return pairingDriver?.hasActiveMachine == true ? .wifiPairingActive : .wifiPairingOnlyIdle
      }
      return .wifiPending
    }

    private func acceptUSBConnection(device: UsbmuxClient.Device, connection newConnection: NWConnection) {
      let current = transportState
      switch USBTransportArbitration.decide(current: current, newcomer: .usb) {
      case .busy:
        transportLogger.info("connection busy transport=usb reason=active-link")
        rejectUSBConnection(device: device, connection: newConnection)
        return
      case .replace:
        transportLogger.info("connection replace transport=usb reason=prefer-usb")
        disconnectSession(notify: true)
      case .accept: break
      }
      pairingDriver?.connectionLost(connectionGeneration)
      hostLink.connectionLost(connectionGeneration)
      connectionGeneration &+= 1
      pairingDriver?.newConnection(connectionGeneration)
      hostLink.newConnection(connectionGeneration)
      connection?.cancel()
      connection = newConnection
      usbDevice = device
      usbConnection = newConnection
      usbConnectionIdentity.set(newConnection)
      usbMode = true
      transportIsUSB = true
      transportLogger.info("connection accept transport=usb reason=arbitration")
      let generation = connectionGeneration
      usbDispatcher = StreamLinkDispatcher(
        transport: NWLinkByteTransport(newConnection),
        onControl: { [weak self] message in
          Task { @MainActor [weak self] in
            guard let self, self.connectionGeneration == generation,
              self.usbConnection === newConnection
            else { return }
            await self.handle(message, connectionGeneration: generation)
          }
        },
        onSample: { [weak self] sample in
          guard let self, self.usbConnectionIdentity.matches(newConnection), self.sampleGate.get()
          else { return }
          let arrival = DispatchTime.now().uptimeNanoseconds
          self.lastPacketAt.set(Date.timeIntervalSinceReferenceDate)
          self.lockedStats.record(sequence: sample.sequence, sender: sample.timestamp, arrival: arrival)
          self.sampleSink.send(sample, arrivalNs: arrival)
        })
      newConnection.stateUpdateHandler = nil
      newConnection.start(queue: queue)
      receiveUSB(from: newConnection)
    }

    private func rejectUSBConnection(device: UsbmuxClient.Device, connection: NWConnection) {
      transportLogger.info("connection close transport=usb reason=busy")
      connection.start(queue: queue)
      connection.send(
        content: Data(StreamFramer.encode(.control(.helloAck(.init(accepted: false, reason: "busy"))))),
        completion: .contentProcessed { [weak self] _ in
          connection.cancel()
          Task { @MainActor [weak self] in
            self?.usbClient?.deviceConnectionEnded(device, connection: connection)
          }
        })
    }

    private func receiveUSB(from expected: NWConnection) {
      expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        [weak self] data, _, complete, error in
        guard let self else { return }
        guard self.usbConnectionIdentity.matches(expected) else { return }
        if let data, !data.isEmpty {
          do {
            try self.usbDispatcher?.receive(data)
          } catch {
            Task { @MainActor [weak self] in
              self?.disconnectSession(notify: self?.hostLink.sessionConnected ?? false)
            }
            return
          }
        }
        if complete || error != nil {
          Task { @MainActor [weak self] in
            guard let self, self.usbConnection === expected else { return }
            self.disconnectSession(notify: self.hostLink.sessionConnected)
          }
        } else {
          self.receiveUSB(from: expected)
        }
      }
    }
  #endif

  private func acceptConnection(_ newConnection: NWConnection) {
    #if os(macOS)
      let current = transportState
      switch USBTransportArbitration.decide(current: current, newcomer: .wifi) {
      case .busy:
        transportLogger.info("connection busy transport=wifi reason=preferred-link")
        rejectConnection(newConnection)
        return
      case .replace:
        transportLogger.info("connection replace transport=wifi reason=new-wifi-link")
        disconnectSession(notify: true)
      case .accept: break
      }
    #else
      if hostLink.sessionConnected || pairingDriver?.hasActiveMachine == true {
        rejectConnection(newConnection)
        return
      }
      if connection != nil { disconnectSession(notify: true) }
    #endif
    if connection != nil {
      // Non-macOS builds have no transport arbitration helper, but still
      // fully clear the previous link before accepting an idle invitation.
      disconnectSession(notify: true)
    }
    connectionGeneration &+= 1
    pairingDriver?.newConnection(connectionGeneration)
    hostLink.newConnection(connectionGeneration)
    connection?.cancel()
    connection = newConnection
    transportLogger.info("connection accept transport=wifi reason=arbitration")
    framer = ControlFramer()
    let generation = connectionGeneration
    controlDispatcher = ControlLinkDispatcher(transport: NWLinkByteTransport(newConnection)) {
      [weak self] message in
      Task { @MainActor [weak self] in await self?.handle(message, connectionGeneration: generation) }
    }
    newConnection.stateUpdateHandler = { [weak self] state in
      guard case .ready = state else { return }
      Task { @MainActor [weak self] in
        guard let self, self.connection === newConnection else { return }
        // The path is available here; accept-time state does not need to guess it.
        if case .hostPort(let host, _) = newConnection.currentPath?.remoteEndpoint {
          self.hostLink.session.setRemoteHost(String(describing: host))
        }
      }
    }
    newConnection.start(queue: queue)
    receiveControl(from: newConnection)
  }

  private func rejectConnection(_ connection: NWConnection) {
    transportLogger.info("connection close transport=wifi reason=busy")
    connection.start(queue: queue)
    connection.send(
      content: Data(ControlFramer().encode(.helloAck(.init(accepted: false, reason: "busy")))),
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private func receiveControl(from expected: NWConnection) {
    expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self, self.connection === expected else { return }
        if let data, !data.isEmpty {
          do {
            try self.controlDispatcher?.receive(data)
          } catch {
            self.disconnectSession(notify: self.hostLink.sessionConnected)
            return
          }
        }
        if complete || error != nil {
          self.disconnectSession(notify: self.hostLink.sessionConnected)
        } else {
          self.receiveControl(from: expected)
        }
      }
    }
  }

  private func handle(_ message: ControlMessage, connectionGeneration generation: UInt64) async {
    guard self.connectionGeneration == generation else { return }
    let now = Date.timeIntervalSinceReferenceDate
    let connectionID = connection == nil ? nil : connectionGeneration
    // Pairing-only gating: only hello, pairRequest/pairReveal/pairResult and
    // ping are processed; samples, gestures and the UDP gate stay idle.
    if let id = connectionID, !hostLink.allows(message, connectionGeneration: id) {
      return
    }
    switch message {
    case .hello(let hello):
      guard let id = connectionID else { return }
      let outcome = hostLink.receiveHello(
        hello, connectionGeneration: id, busy: hostLink.sessionConnected, now: now,
        hostAppVersion: hostInfo?.appVersion ?? "unknown")
      switch outcome {
      case .reject(let ack, _):
        sendControl(.helloAck(ack))
        disconnectSession(notify: false)
        return
      case .busy(let ack):
        sendControl(.helloAck(ack))
        connection?.cancel()
        connection = nil
        return
      case .pairingRequired(let ack):
        // Keep the connection open in a pairing-only state.
        sendControl(.helloAck(ack))
        return
      case .needsAccept, .authenticated:
        break
      }
      // The prompt may take seconds; a newer unaccepted connection can
      // replace this one meanwhile, and must not inherit the answer.
      let asking = connection
      let allowed: Bool
      if case .authenticated = outcome {
        // A paired iPad proved its key; pairing already had the user's consent.
        allowed = true
      } else {
        allowed = await accept(hello)
        guard let asking, connection === asking, !hostLink.sessionConnected else {
          asking?.cancel()
          return
        }
      }
      guard allowed else {
        sendControl(.helloAck(.init(accepted: false, reason: "rejected")))
        disconnectSession(notify: false)
        return
      }
      let udpPort = udpListener?.port?.rawValue ?? 0
      #if os(macOS)
        if !usbMode && udpListener?.port == nil {
          sendControl(.helloAck(.init(accepted: false, reason: "UDP listener unavailable")))
          disconnectSession(notify: false)
          return
        }
      #else
        guard udpListener?.port != nil else {
          sendControl(.helloAck(.init(accepted: false, reason: "UDP listener unavailable")))
          disconnectSession(notify: false)
          return
        }
      #endif
      let ack = hostLink.acceptHello(
        hello, now: now, udpPort: udpPort, displayWidth: displayWidth,
        displayHeight: displayHeight, host: hostInfo)
      // Only the accepted control connection's host may send samples.
      var tcpHost = hostLink.session.remoteHost
      if tcpHost == nil, case .hostPort(let host, _) = connection?.currentPath?.remoteEndpoint {
        tcpHost = String(describing: host)
      }
      #if os(macOS)
        if usbMode { udpGate.disable() } else { udpGate.configure(host: tcpHost) }
      #else
        udpGate.configure(host: tcpHost)
      #endif
      sampleGate.set(true)
      lastPacketAt.set(now)
      lockedStats.reset()
      linkStats = LinkStats()
      rttSamples.removeAll()
      latestRTTMs = nil
      transportLogger.info("session accepted from \(hello.deviceName, privacy: .public)")
      // A .send never goes to a different connection: verify the asker is
      // still current before sending the ack.
      guard connection === asking else { return }
      sendControl(.helloAck(ack))
      onSession?(.connected(hello))
      startHeartbeat()
    case .geometry(let geometry):
      guard hostLink.sessionConnected else { return }
      hostLink.session.received(at: now)
      onSession?(.geometryChanged(geometry))
    case .ping:
      if hostLink.sessionConnected {
        hostLink.session.received(at: now)
      }
      // In pairing-only ping keeps the connection open; no session to refresh.
      return
    case .probe(let sentAtNs):
      guard hostLink.sessionConnected else { return }
      hostLink.session.received(at: now)
      sendControl(.probeReply(sentAtNs: sentAtNs))
    case .gesture(let gesture):
      guard hostLink.sessionConnected else { return }
      hostLink.session.received(at: now)
      onGesture?(gesture)
    case .frontApp:
      guard hostLink.sessionConnected else { return }
    case .probeReply(let sentAtNs):
      guard hostLink.sessionConnected else { return }
      let nowNs = DispatchTime.now().uptimeNanoseconds
      guard nowNs >= sentAtNs else { return }
      let rtt = Double(nowNs - sentAtNs) / 1_000_000
      rttSamples.append(rtt)
      if rttSamples.count > 10 { rttSamples.removeFirst() }
      latestRTTMs = rttSamples.sorted()[rttSamples.count / 2]
    case .helloAck: break
    case .pairRequest, .pairResponse, .pairReveal, .pairResult:
      handlePairingMessage(message)
    }
  }

  public func sendControl(_ message: ControlMessage) {
    guard let connection else { return }
    #if os(macOS)
      if usbMode {
        connection.send(
          content: Data(StreamFramer.encode(.control(message))), completion: .contentProcessed { _ in })
        return
      }
    #endif
    connection.send(content: Data(ControlFramer().encode(message)), completion: .contentProcessed { _ in })
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        if let packetAt = self.lastPacketAt.get() { self.hostLink.session.received(at: packetAt) }
        if self.hostLink.session.timeoutIfNeeded(at: Date.timeIntervalSinceReferenceDate) {
          self.disconnectSession(notify: true)
          return
        }
        self.sendControl(.ping)
        self.sendControl(.probe(sentAtNs: DispatchTime.now().uptimeNanoseconds))
      }
    }
  }

  private func acceptUDP(_ udp: NWConnection) {
    guard hostLink.sessionConnected else {
      udp.cancel()
      return
    }
    udp.start(queue: queue)
    receiveUDP(udp)
  }

  private nonisolated func receiveUDP(_ udp: NWConnection) {
    udp.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      let arrival = DispatchTime.now().uptimeNanoseconds
      if let data, data.count == PenSample.byteCount,
        let sample = try? PenSample(decoding: Array(data)),
        case .hostPort(let host, _) = udp.currentPath?.remoteEndpoint,
        self.udpGate.accepts(host: String(describing: host), sequence: sample.sequence)
      {
        self.lastPacketAt.set(Date.timeIntervalSinceReferenceDate)
        self.lockedStats.record(sequence: sample.sequence, sender: sample.timestamp, arrival: arrival)
        self.sampleSink.send(sample, arrivalNs: arrival)
      }
      if error == nil { self.receiveUDP(udp) }
    }
  }

  private func disconnectSession(notify: Bool) {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    pairingDriver?.connectionLost(connectionGeneration)
    hostLink.connectionLost(connectionGeneration)
    connection?.cancel()
    connection = nil
    controlDispatcher = nil
    #if os(macOS)
      let endedDevice = usbDevice
      let endedConnection = usbConnection
      usbConnection?.cancel()
      usbConnection = nil
      usbDevice = nil
      usbConnectionIdentity.set(nil)
      usbMode = false
      transportIsUSB = false
      usbDispatcher = nil
      if let endedDevice, let endedConnection {
        usbClient?.deviceConnectionEnded(endedDevice, connection: endedConnection)
      }
    #endif
    hostLink.session.disconnect()
    udpGate.disable()
    sampleGate.set(false)
    lastPacketAt.set(nil)
    lockedStats.reset()
    linkStats = LinkStats()
    rttSamples.removeAll()
    latestRTTMs = nil
    hostLink.sessionConnected = false
    framer = ControlFramer()
    if notify { onSession?(.disconnected) }
    if notify { transportLogger.info("session disconnected") }
  }
}
