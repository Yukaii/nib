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
  public private(set) var state: PenLinkState = .searching {
    didSet {
      transportLogger.info("sender state: \(String(describing: self.state), privacy: .public)")
      stateHandler?(self.state)
    }
  }
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

  public func send(_ gesture: Gesture) { sendControl(.gesture(gesture)) }

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
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let tcpParameters = NWParameters(tls: nil, tcp: tcpOptions)
    let newConnection = NWConnection(
      to: .service(name: name, type: type, domain: domain, interface: interface), using: tcpParameters)
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
        transportLogger.info("session rejected: \(ack.reason ?? "unknown", privacy: .public)")
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
      state = .connected(name)
      startHeartbeat()
    case .probe(let sentAtNs):
      sendControl(.probeReply(sentAtNs: sentAtNs))
    case .probeReply: break
    // Pings are never echoed: both sides send their own every second, and
    // echoing would make each one ping-pong forever.
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

  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.yukai.nib.receiver")
  private var connection: NWConnection?
  #if os(macOS)
    private var usbClient: UsbmuxClient?
    private var usbConnection: NWConnection?
    private var usbFramer = StreamFramer()
    private var usbMode = false
  #endif
  private var udpListener: NWListener?
  private var framer = ControlFramer()
  private var session = ReceiverSession()
  private var heartbeatTask: Task<Void, Never>?
  private var sessionConnected = false
  private var busyFramers: [ObjectIdentifier: ControlFramer] = [:]
  private let udpGate = UDPGate()
  private let lockedStats = LockedStats()
  private let sampleSink = SampleSink()
  private let lastPacketAt = LockedTimestamp()
  private var linkStats = LinkStats()
  private var rttSamples: [Double] = []
  public private(set) var latestRTTMs: Double?
  public private(set) var transportIsUSB = false

  public init(accept: @escaping AcceptHandler = { _ in true }) throws {
    self.accept = accept
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let tcpParameters = NWParameters(tls: nil, tcp: tcpOptions)
    listener = try NWListener(using: tcpParameters)
    listener.service = NWListener.Service(type: "_nib._tcp")
    listener.newConnectionHandler = { [weak self] newConnection in
      Task { @MainActor [weak self] in self?.acceptConnection(newConnection) }
    }
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
      client.onDeviceConnection = { [weak self] _, connection in
        self?.acceptUSBConnection(connection)
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
    disconnectSession(notify: sessionConnected)
    #if os(macOS)
      usbClient?.stop()
      usbClient = nil
    #endif
  }

  #if os(macOS)
    private func acceptUSBConnection(_ newConnection: NWConnection) {
      if sessionConnected {
        newConnection.start(queue: queue)
        newConnection.send(
          content: Data(StreamFramer.encode(.control(.helloAck(.init(accepted: false, reason: "busy"))))),
          completion: .contentProcessed { _ in newConnection.cancel() })
        return
      }
      connection?.cancel()
      connection = newConnection
      usbConnection = newConnection
      usbMode = true
      transportIsUSB = true
      usbFramer = StreamFramer()
      newConnection.stateUpdateHandler = nil
      newConnection.start(queue: queue)
      receiveUSB(from: newConnection)
    }

    private func receiveUSB(from expected: NWConnection) {
      expected.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        [weak self] data, _, complete, error in
        guard let self else { return }
        if let data, !data.isEmpty {
          do {
            let frames = try self.usbFramer.append(Array(data))
            for frame in frames {
              switch frame {
              case .control(let message):
                Task { @MainActor [weak self] in
                  guard let self, self.usbConnection === expected else { return }
                  await self.handle(message)
                }
              case .sample(let sample):
                let arrival = DispatchTime.now().uptimeNanoseconds
                self.lastPacketAt.set(Date.timeIntervalSinceReferenceDate)
                self.lockedStats.record(sequence: sample.sequence, sender: sample.timestamp, arrival: arrival)
                self.sampleSink.send(sample, arrivalNs: arrival)
              }
            }
          } catch {
            Task { @MainActor [weak self] in self?.disconnectSession(notify: self?.sessionConnected ?? false)
            }
            return
          }
        }
        if complete || error != nil {
          Task { @MainActor [weak self] in
            guard let self, self.usbConnection === expected else { return }
            self.disconnectSession(notify: self.sessionConnected)
          }
        } else {
          self.receiveUSB(from: expected)
        }
      }
    }
  #endif

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
      // The prompt may take seconds; a newer unaccepted connection can
      // replace this one meanwhile, and must not inherit the answer.
      let asking = connection
      let allowed = await accept(hello)
      guard let asking, connection === asking, !sessionConnected else {
        asking?.cancel()
        return
      }
      guard allowed else {
        sendControl(.helloAck(.init(accepted: false, reason: "rejected")))
        connection?.cancel()
        connection = nil
        return
      }
      _ = session.hello(protocolVersion: hello.protocolVersion, busy: false, acceptResult: true, now: now)
      let udpPort = udpListener?.port?.rawValue ?? 0
      #if os(macOS)
        if !usbMode && udpListener?.port == nil {
          sendControl(.helloAck(.init(accepted: false, reason: "UDP listener unavailable")))
          connection?.cancel()
          connection = nil
          return
        }
      #else
        guard udpListener?.port != nil else {
          sendControl(.helloAck(.init(accepted: false, reason: "UDP listener unavailable")))
          connection?.cancel()
          connection = nil
          return
        }
      #endif
      sessionConnected = true
      // Only the accepted control connection's host may send samples.
      var tcpHost = session.remoteHost
      if tcpHost == nil, case .hostPort(let host, _) = connection?.currentPath?.remoteEndpoint {
        tcpHost = String(describing: host)
      }
      #if os(macOS)
        if usbMode { udpGate.disable() } else { udpGate.configure(host: tcpHost) }
      #else
        udpGate.configure(host: tcpHost)
      #endif
      lastPacketAt.set(now)
      lockedStats.reset()
      linkStats = LinkStats()
      rttSamples.removeAll()
      latestRTTMs = nil
      transportLogger.info("session accepted from \(hello.deviceName, privacy: .public)")
      sendControl(
        .helloAck(
          .init(
            accepted: true, udpPort: udpPort, displayWidth: displayWidth,
            displayHeight: displayHeight)))
      onSession?(.connected(hello))
      startHeartbeat()
    case .geometry(let geometry):
      guard sessionConnected else { return }
      session.received(at: now)
      onSession?(.geometryChanged(geometry))
    case .ping:
      guard sessionConnected else { return }
      session.received(at: now)
    case .probe(let sentAtNs):
      guard sessionConnected else { return }
      session.received(at: now)
      sendControl(.probeReply(sentAtNs: sentAtNs))
    case .gesture(let gesture):
      guard sessionConnected else { return }
      session.received(at: now)
      onGesture?(gesture)
    case .probeReply(let sentAtNs):
      guard sessionConnected else { return }
      let nowNs = DispatchTime.now().uptimeNanoseconds
      guard nowNs >= sentAtNs else { return }
      let rtt = Double(nowNs - sentAtNs) / 1_000_000
      rttSamples.append(rtt)
      if rttSamples.count > 10 { rttSamples.removeFirst() }
      latestRTTMs = rttSamples.sorted()[rttSamples.count / 2]
    case .helloAck: break
    }
  }

  private func sendControl(_ message: ControlMessage) {
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
        if let packetAt = self.lastPacketAt.get() { self.session.received(at: packetAt) }
        if self.session.timeoutIfNeeded(at: Date.timeIntervalSinceReferenceDate) {
          self.disconnectSession(notify: true)
          return
        }
        self.sendControl(.ping)
        self.sendControl(.probe(sentAtNs: DispatchTime.now().uptimeNanoseconds))
      }
    }
  }

  private func acceptUDP(_ udp: NWConnection) {
    guard sessionConnected else {
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
    connection?.cancel()
    connection = nil
    #if os(macOS)
      usbConnection?.cancel()
      usbConnection = nil
      usbMode = false
      transportIsUSB = false
      usbFramer = StreamFramer()
    #endif
    session.disconnect()
    udpGate.disable()
    lastPacketAt.set(nil)
    lockedStats.reset()
    linkStats = LinkStats()
    rttSamples.removeAll()
    latestRTTMs = nil
    sessionConnected = false
    framer = ControlFramer()
    if notify { onSession?(.disconnected) }
    if notify { transportLogger.info("session disconnected") }
  }
}
