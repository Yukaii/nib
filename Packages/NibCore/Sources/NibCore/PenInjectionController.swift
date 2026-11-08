#if os(macOS)
  import AppKit
  import CoreGraphics

  /// Connects received samples to the tablet event builder and Quartz poster.
  public struct PenInjectionController {
    public private(set) var mapper: DisplayMapper
    public private(set) var accessibilityTrusted = false

    private var builder = TabletEventBuilder()
    private var gestureBuilder = GestureEventBuilder()
    private let post: ([CGEvent]) -> Void
    private let trust: () -> Bool

    public init(
      surfaceSize: CGSize = .zero, displayRect: CGRect = .zero,
      post: @escaping ([CGEvent]) -> Void,
      isTrusted: @escaping () -> Bool = { TabletInjector.isTrusted }
    ) {
      mapper = DisplayMapper(surfaceSize: surfaceSize, displayRect: displayRect)
      self.post = post
      trust = isTrusted
      accessibilityTrusted = isTrusted()
    }

    /// The trust check is too slow for the 240 Hz sample path; the host
    /// refreshes it on a timer instead.
    @discardableResult
    public mutating func refreshTrust() -> Bool {
      accessibilityTrusted = trust()
      return accessibilityTrusted
    }

    @discardableResult
    public mutating func handle(_ sample: PenSample) -> Bool {
      guard accessibilityTrusted else { return false }
      var events = sample.kind == .down ? gestureBuilder.releaseHeldModifier() : []
      events += builder.events(for: sample, at: mapper.map(sample))
      guard !events.isEmpty else { return true }
      post(events)
      return true
    }

    @discardableResult
    public mutating func handle(_ gesture: Gesture) -> Bool {
      guard accessibilityTrusted else { return false }
      let events = gestureBuilder.events(for: gesture)
      guard !events.isEmpty else { return true }
      post(events)
      return true
    }

    public mutating func surfaceChanged(_ size: CGSize) {
      mapper.surfaceChanged(size)
    }

    public mutating func mappingChanged(
      _ rect: CGRect, proportions: MappingSettings.Proportions
    ) {
      mapper.mappingChanged(rect, proportions: proportions)
    }

    public mutating func sessionEnded() {
      guard accessibilityTrusted else { return }
      let sample = PenSample(
        kind: .proximityExit, sequence: 0, timestamp: 0, x: 0, y: 0, pressure: 0, altitude: 0,
        azimuth: 0)
      let events = gestureBuilder.releaseAll() + builder.events(for: sample, at: mapper.map(sample))
      if !events.isEmpty { post(events) }
    }
  }
#endif

#if os(macOS)
  /// The worker writes the result before signaling; the semaphore establishes visibility to the caller.
  private final class TrustResult: @unchecked Sendable { var value = false }

  /// Serializes all controller, scheduler, timer, and CGEvent work on one queue.
  /// The unchecked conformance is safe because every mutable property is accessed only there.
  public final class PenInjectionWorker: @unchecked Sendable {
    public struct Snapshot: Sendable {
      public let injectP95Ms: Double
      public let playoutDelayMs: Double
      public init(injectP95Ms: Double, playoutDelayMs: Double) {
        self.injectP95Ms = injectP95Ms
        self.playoutDelayMs = playoutDelayMs
      }
    }

    private let queue: DispatchQueue
    private var controller: PenInjectionController
    private var scheduler: PlayoutScheduler
    private var timer: DispatchSourceTimer?
    // Written on the worker queue, read by snapshot() on the main actor; guarded by statsLock.
    private let statsLock = NSLock()
    private var postTimes: [Double] = []
    private var latestDelayMs: Double = 2

    public init(
      surfaceSize: CGSize = .zero, displayRect: CGRect = .zero,
      post: @escaping ([CGEvent]) -> Void,
      isTrusted: @escaping () -> Bool = { TabletInjector.isTrusted },
      smoothing: Bool = true
    ) {
      queue = DispatchQueue(label: "dev.yukai.nib.injection", qos: .userInteractive)
      controller = PenInjectionController(
        surfaceSize: surfaceSize, displayRect: displayRect, post: post, isTrusted: isTrusted)
      scheduler = PlayoutScheduler(mode: smoothing ? .smoothing : .passthrough)
    }

    public func enqueue(_ gesture: Gesture) {
      queue.async { [self] in
        guard controller.accessibilityTrusted else { return }
        _ = controller.handle(gesture)
      }
    }

    public func enqueue(_ sample: PenSample, arrivalNs: UInt64) {
      queue.async { [self] in
        let now = DispatchTime.now().uptimeNanoseconds
        let immediate = scheduler.enqueue(sample, arrivalNs: arrivalNs)
        post(immediate, nowNs: now)
        drainTimer()
      }
    }

    public func setSmoothing(_ enabled: Bool) {
      queue.async { [self] in
        scheduler.setMode(enabled ? .smoothing : .passthrough)
        if !enabled { cancelTimer() }
      }
    }

    public func mappingChanged(_ rect: CGRect, proportions: MappingSettings.Proportions) {
      queue.async { [self] in controller.mappingChanged(rect, proportions: proportions) }
    }
    public func surfaceChanged(_ size: CGSize) { queue.async { [self] in controller.surfaceChanged(size) } }
    public func sessionEnded() { queue.async { [self] in controller.sessionEnded() } }
    public func refreshTrust() -> Bool {
      // Trust is polled by the main actor; the result is delivered asynchronously to the worker.
      let semaphore = DispatchSemaphore(value: 0)
      let result = TrustResult()
      queue.async { [self, result] in
        result.value = controller.refreshTrust()
        semaphore.signal()
      }
      semaphore.wait()
      return result.value
    }
    public func snapshot() -> Snapshot {
      statsLock.lock()
      let times = postTimes
      let delay = latestDelayMs
      statsLock.unlock()
      // Sorted here, once per menu refresh, not on every 1 ms drain tick.
      let sorted = times.sorted()
      let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
      return Snapshot(injectP95Ms: p95, playoutDelayMs: delay)
    }

    private func drainTimer() {
      guard timer == nil else { return }
      let source = DispatchSource.makeTimerSource(queue: queue)
      timer = source
      source.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(1))
      source.setEventHandler { [weak self] in self?.drainPending() }
      source.setCancelHandler {}
      source.resume()
    }

    private func drainPending() {
      let now = DispatchTime.now().uptimeNanoseconds
      let samples = scheduler.drain(nowNs: now)
      post(samples, nowNs: now)
      if !scheduler.hasPending { cancelTimer() }
    }

    private func cancelTimer() {
      timer?.cancel()
      timer = nil
    }

    private func post(_ samples: [PenSample], nowNs: UInt64) {
      guard !samples.isEmpty else { return }
      var durations: [Double] = []
      for sample in samples {
        let started = DispatchTime.now().uptimeNanoseconds
        _ = controller.handle(sample)
        durations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
      }
      statsLock.lock()
      postTimes.append(contentsOf: durations)
      if postTimes.count > 240 { postTimes.removeFirst(postTimes.count - 240) }
      latestDelayMs = scheduler.playoutDelayMs
      statsLock.unlock()
    }
  }
#endif
