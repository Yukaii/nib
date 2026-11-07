import Foundation

/// Shared pairing/timeout driving used by the Wi-Fi receiver, the Wi-Fi sender
/// and the USB listener. The machine belongs to the connection that started it
/// (`ObjectIdentifier` of the `NWConnection` in production, a dummy object in
/// tests) and is reset when that connection is lost. A new connection never
/// inherits it, and a `.send` never goes to a different connection.
@MainActor
public final class PairingDriver {
  private var machine: PairingStateMachine?
  private var connection: ObjectIdentifier?
  private var timeoutTask: Task<Void, Never>?
  private let store: PairingKeyStore
  private let role: PairingRole
  private var localID: String
  private var localName: () -> String
  private var limiter = PairingAttemptLimiter()
  /// Injected clock for attempt limiting and tests.
  public var clock: () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
  /// Timeout for tests; production uses `PairingTransportPolicy.timeoutSeconds`.
  public var timeoutSeconds: UInt64 = PairingTransportPolicy.timeoutSeconds
  /// Sends on the bound connection only; the owner checks the connection.
  public var onSend: ((ControlMessage) -> Void)?
  public var onEvent: ((PairingTransportEvent) -> Void)?

  public init(
    role: PairingRole, localID: String, localName: @escaping () -> String, store: PairingKeyStore
  ) {
    self.role = role
    self.localID = localID
    self.localName = localName
    self.store = store
  }

  public var phase: PairingPhase? { machine?.phase }
  public var peerDisplayName: String? { machine?.peerDisplayName }
  public var boundConnection: ObjectIdentifier? { connection }

  public func updateLocal(id: String, name: @escaping () -> String) {
    localID = id
    localName = name
  }

  // MARK: - Device role

  public func beginPairing(deviceID: String, deviceName: String, connectionID: ObjectIdentifier) {
    guard role == .device else { return }
    if let machine, !machine.isTerminal { return }
    var fresh = PairingStateMachine(role: .device, id: deviceID, name: deviceName, store: store)
    guard let event = try? fresh.begin() else { return }
    machine = fresh
    connection = connectionID
    startTimeout()
    if case .send(let message) = event { sendIfBound(message, connectionID: connectionID) }
  }

  // MARK: - Common

  public func receive(_ message: ControlMessage, connectionID: ObjectIdentifier) {
    // Host creates its machine on the first pairRequest; device ignores
    // pairing traffic with no machine.
    if machine == nil {
      guard role == .host, case .pairRequest = message else { return }
      let now = clock()
      if !limiter.canAttempt(at: now) {
        onSend?(
          .pairResult(
            .init(accepted: false, reason: PairingAttemptLimiter.refusalReason())))
        return
      }
      machine = PairingStateMachine(
        role: .host, id: localID, name: localName(), store: store)
      connection = connectionID
      startTimeout()
    }
    guard let bound = connection, bound == connectionID, var machine else { return }
    let events = machine.receive(message)
    self.machine = machine
    process(events, connectionID: connectionID)
  }

  public func confirm(connectionID: ObjectIdentifier) {
    guard let bound = connection, bound == connectionID, var machine else { return }
    let events = machine.confirm()
    self.machine = machine
    process(events, connectionID: connectionID)
  }

  public func cancel(connectionID: ObjectIdentifier) {
    guard let bound = connection, bound == connectionID, var machine else { return }
    let event = machine.cancel()
    self.machine = machine
    if case .send(let message) = event { sendIfBound(message, connectionID: connectionID) }
    // `cancel()` always moves to `.cancelled`.
    if role == .host { limiter.recordFailure(at: clock()) }
    finish(with: .cancelled)
  }

  public func connectionLost(_ id: ObjectIdentifier) {
    guard connection == id else { return }
    cancelTimeout()
    machine = nil
    connection = nil
  }

  public func newConnection(_ id: ObjectIdentifier) {
    // A new connection never inherits pairing in progress.
    if let bound = connection, bound != id {
      cancelTimeout()
      machine = nil
      connection = nil
    }
  }

  /// Fires the 60 s timeout immediately (tests and manual expiry).
  public func timeoutNow() {
    guard var machine, !machine.isTerminal else { return }
    let event = machine.timeout()
    self.machine = machine
    if role == .host { limiter.recordFailure(at: clock()) }
    if case .timedOut = event { finish(with: .timedOut) }
  }

  private func process(_ events: [PairingEvent], connectionID: ObjectIdentifier) {
    for event in events {
      switch event {
      case .send(let message):
        sendIfBound(message, connectionID: connectionID)
      case .showCode(let code):
        let peer = machine?.peerDisplayName ?? (role == .host ? "iPad" : "Mac")
        onEvent?(.showCode(code, peerName: peer))
      case .paired(let peerID):
        cancelTimeout()
        // Host limiter records failures only; successes need no entry.
        machine = nil
        connection = nil
        onEvent?(.paired(peerID: peerID))
      case .cancelled:
        if role == .host { limiter.recordFailure(at: clock()) }
        finish(with: .cancelled)
      case .timedOut:
        if role == .host { limiter.recordFailure(at: clock()) }
        finish(with: .timedOut)
      case .failed(let reason):
        if role == .host { limiter.recordFailure(at: clock()) }
        finish(with: .failed(reason))
      }
    }
    // Terminal machines are cleared by finish/paired above; nothing extra here.
  }

  private func sendIfBound(_ message: ControlMessage, connectionID: ObjectIdentifier) {
    guard connection == connectionID else { return }
    onSend?(message)
  }

  private func finish(with event: PairingTransportEvent) {
    cancelTimeout()
    machine = nil
    connection = nil
    onEvent?(event)
  }

  private func startTimeout() {
    cancelTimeout()
    let seconds = timeoutSeconds
    timeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Int(seconds)))
      guard let self, !Task.isCancelled else { return }
      self.timeoutNow()
    }
  }

  private func cancelTimeout() {
    timeoutTask?.cancel()
    timeoutTask = nil
  }
}
