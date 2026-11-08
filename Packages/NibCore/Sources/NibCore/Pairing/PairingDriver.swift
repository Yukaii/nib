import Foundation

/// Shared pairing/timeout driving used by the Wi-Fi receiver, the Wi-Fi sender
/// and the USB listener. The machine belongs to the connection that started it
/// A monotonically increasing connection generation owns the machine.
@MainActor
public final class PairingDriver {
  private var machine: PairingStateMachine?
  private var connection: UInt64?
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
  /// Sends on the bound connection only; the owner checks the generation.
  public var onSend: ((ControlMessage) -> Void)?
  /// Used only for an attempt-limit refusal, before a machine is bound.
  public var onSendUnbound: ((ControlMessage, UInt64) -> Void)?
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
  public var hasActiveMachine: Bool { machine != nil }
  public var peerDisplayName: String? { machine?.peerDisplayName }
  public var boundGeneration: UInt64? { connection }
  public func updateLocal(id: String, name: @escaping () -> String) {
    localID = id
    localName = name
  }

  // MARK: - Device role

  public func beginPairing(deviceID: String, deviceName: String, connectionGeneration: UInt64) {
    guard role == .device else { return }
    if let machine, !machine.isTerminal { return }
    var fresh = PairingStateMachine(role: .device, id: deviceID, name: deviceName, store: store)
    guard let event = try? fresh.begin() else { return }
    machine = fresh
    connection = connectionGeneration
    startTimeout()
    if case .send(let message) = event { sendIfBound(message, connectionGeneration: connectionGeneration) }
  }

  // MARK: - Common

  public func receive(_ message: ControlMessage, connectionGeneration: UInt64) {
    // Host creates its machine on the first pairRequest; device ignores
    // pairing traffic with no machine.
    if machine == nil {
      guard role == .host, case .pairRequest = message else { return }
      let now = clock()
      if !limiter.canAttempt(at: now) {
        onSendUnbound?(
          .pairResult(.init(accepted: false, reason: PairingAttemptLimiter.refusalReason())),
          connectionGeneration)
        return
      }
      machine = PairingStateMachine(
        role: .host, id: localID, name: localName(), store: store)
      connection = connectionGeneration
      startTimeout()
    }
    guard let bound = connection, bound == connectionGeneration, var machine else { return }
    let events = machine.receive(message)
    self.machine = machine
    process(events, connectionGeneration: connectionGeneration)
  }

  public func confirm(connectionGeneration: UInt64) {
    guard let bound = connection, bound == connectionGeneration, var machine else { return }
    let events = machine.confirm()
    self.machine = machine
    process(events, connectionGeneration: connectionGeneration)
  }

  public func cancel(connectionGeneration: UInt64) {
    guard let bound = connection, bound == connectionGeneration, var machine else { return }
    let event = machine.cancel()
    self.machine = machine
    if case .send(let message) = event { sendIfBound(message, connectionGeneration: connectionGeneration) }
    // `cancel()` always moves to `.cancelled`.
    if role == .host { limiter.recordFailure(at: clock()) }
    finish(with: .cancelled)
  }

  public func connectionLost(_ generation: UInt64) {
    guard connection == generation else { return }
    let hadActivePairing = machine != nil && machine?.isTerminal == false
    cancelTimeout()
    machine = nil
    connection = nil
    if hadActivePairing {
      onEvent?(.failed("Connection lost. Try pairing again."))
    }
  }

  public func newConnection(_ generation: UInt64) {
    // A new connection never inherits pairing in progress.
    if let bound = connection, bound != generation {
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

  private func process(_ events: [PairingEvent], connectionGeneration: UInt64) {
    for event in events {
      switch event {
      case .send(let message):
        sendIfBound(message, connectionGeneration: connectionGeneration)
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

  private func sendIfBound(_ message: ControlMessage, connectionGeneration: UInt64) {
    guard connection == connectionGeneration else { return }
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
