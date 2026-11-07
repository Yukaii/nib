import NibCore
import SwiftUI
import UIKit
import os

private let padLogger = Logger(subsystem: "dev.yukai.nib", category: "pad")

@MainActor
protocol PenSampleSink: AnyObject {
  var linkState: String { get }
  func send(_ sample: PenSample)
  func updateGeometry(width: Double, height: Double)
}

@MainActor
final class LoggingSink: PenSampleSink {
  private(set) var latestSample: PenSample?
  var linkState: String { "preview" }
  func send(_ sample: PenSample) { latestSample = sample }
  func updateGeometry(width: Double, height: Double) {}
}

@MainActor
final class PenCaptureView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
  let sink: PenSampleSink
  private var sequence: UInt32 = 0
  private var buttons: PenSample.Buttons = []
  private var wasActive = false
  private var panelOpen = false
  var onPanelToggle: (() -> Void)?
  private var originalBrightness: CGFloat?
  private var hudVisible = false
  private var strokeStartedAt: TimeInterval?
  private var strokeMoves = 0
  private let hud = PenHUDView()
  private var hoverRecognizer: UIHoverGestureRecognizer?
  private var fingerGestures: FingerGestureController!
  private var lastSample: PenSample?
  private var isTouching = false
  private var pendingProximityExit: Task<Void, Never>?
  private var inkPoints: [(point: CGPoint, time: TimeInterval)] = []
  private var sampleTimes: [TimeInterval] = []
  private static let traceLifetime: TimeInterval = 1.0
  // Hover ends the moment the Pencil touches the glass, and a lifted Pencil
  // may resume hovering a few frames later; only a lasting absence is an exit.
  private static let proximityExitDelay: Duration = .milliseconds(150)

  init(sink: PenSampleSink = LoggingSink()) {
    self.sink = sink
    super.init(frame: .zero)
    isMultipleTouchEnabled = true
    backgroundColor = .black
    addSubview(hud)
    hud.isHidden = true
    let panelTap = UITapGestureRecognizer(target: self, action: #selector(togglePanel))
    panelTap.numberOfTouchesRequired = 4
    panelTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    panelTap.delegate = self
    addGestureRecognizer(panelTap)
    fingerGestures = FingerGestureController(
      view: self,
      send: { [weak sink] gesture in (sink as? GestureSink)?.send(gesture) },
      settings: { [weak sink] in (sink as? GestureSink)?.padSettings ?? PadSettings() })
    if #available(iOS 16.0, *) {
      let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
      hoverRecognizer = hover
      addGestureRecognizer(hover)
    }
    let pencil = UIPencilInteraction()
    pencil.delegate = self
    addInteraction(pencil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(willResignActive),
      name: UIApplication.willResignActiveNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil
    )
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    hud.frame = bounds
    sink.updateGeometry(width: Double(bounds.width), height: Double(bounds.height))
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { activateScreenOffMode() } else { restoreScreen() }
  }

  @objc private func willResignActive() { restoreScreen() }

  @objc private func didBecomeActive() {
    if window != nil { activateScreenOffMode() }
  }

  private func activateScreenOffMode() {
    guard !wasActive else { return }
    wasActive = true
    originalBrightness = UIScreen.main.brightness
    applyBrightness()
    padLogger.info("screen-off mode enabled")
    UIApplication.shared.isIdleTimerDisabled = true
  }

  private func restoreScreen() {
    guard wasActive else { return }
    wasActive = false
    UIApplication.shared.isIdleTimerDisabled = false
    if let originalBrightness { UIScreen.main.brightness = originalBrightness }
    padLogger.info("screen-off mode disabled")
    self.originalBrightness = nil
  }

  @objc private func togglePanel() {
    onPanelToggle?()
  }

  func setPanelOpen(_ open: Bool) {
    guard panelOpen != open else { return }
    panelOpen = open
    if open {
      // Sends stop while the panel is open; release the pen on the Mac first so
      // a stroke or hover in progress cannot leave the button held.
      cancelProximityExit()
      isTouching = false
      if lastSample?.kind != .proximityExit {
        sink.send(
          PenSample(
            kind: .proximityExit, sequence: nextSequence(), timestamp: timestamp(),
            x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, buttons: buttons))
      }
      inkPoints.removeAll()
      sampleTimes.removeAll()
      hud.clearTrace()
    }
    applyBrightness()
  }

  func setHUDVisible(_ visible: Bool) {
    hud.isHidden = !visible
    hudVisible = visible
    applyBrightness()
  }

  /// One place decides brightness: dark only while drawing blind. With the
  /// panel or HUD showing, use the user's brightness, but never so low that
  /// the overlay is unreadable.
  private func applyBrightness() {
    guard wasActive else { return }
    if panelOpen || hudVisible {
      UIScreen.main.brightness = max(originalBrightness ?? 0.5, 0.5)
    } else {
      UIScreen.main.brightness = 0
    }
  }

  func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
    buttons.formSymmetricDifference(.eraser)
  }

  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    if squeeze.phase == .ended {
      buttons.formSymmetricDifference(.eraser)
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    handle(touches, kind: .down, event: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    handle(touches, kind: .move, event: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    handle(touches, kind: .up, event: event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    handle(touches, kind: .cancel, event: event)
  }

  private func handle(_ touches: Set<UITouch>, kind: PenSample.Kind, event: UIEvent?) {
    for touch in touches where touch.type == .pencil {
      switch kind {
      case .down:
        isTouching = true
        strokeStartedAt = touch.timestamp
        strokeMoves = 0
        padLogger.info("pencil down force=\(touch.force, privacy: .public)")
        fingerGestures.pencilBegan()
        cancelProximityExit()
      case .up, .cancel:
        // Stroke-level only: lines up with bluetoothd in the device log when
        // diagnosing Pencil dropouts.
        padLogger.info(
          "pencil \(kind == .up ? "up" : "CANCEL", privacy: .public) after \(String(format: "%.2f", touch.timestamp - (self.strokeStartedAt ?? touch.timestamp)), privacy: .public)s moves=\(self.strokeMoves, privacy: .public) force=\(touch.force, privacy: .public)"
        )
        isTouching = false
        fingerGestures.pencilEnded()
        scheduleProximityExit()
      default:
        break
      }
      if kind == .move { strokeMoves += 1 }
      let coalesced = (kind == .move ? event?.coalescedTouches(for: touch) : nil) ?? [touch]
      for sampleTouch in coalesced {
        emit(sampleTouch, kind: kind, flags: coalesced.count > 1 ? .coalesced : [])
      }
      if kind == .move, let predicted = event?.predictedTouches(for: touch) {
        for predictedTouch in predicted {
          emit(predictedTouch, kind: .move, flags: .predicted)
        }
      }
    }
  }

  private func emit(_ touch: UITouch, kind: PenSample.Kind, flags: PenSample.Flags) {
    let point = touch.location(in: self)
    let normalized = PencilNormalizer.normalize(
      location: SIMD2(Float(point.x), Float(point.y)),
      viewSize: SIMD2(Float(bounds.width), Float(bounds.height)),
      force: Float(touch.force), maximumPossibleForce: Float(touch.maximumPossibleForce),
      altitude: Float(touch.altitudeAngle), azimuth: Float(touch.azimuthAngle(in: self))
    )
    let sample = PenSample(
      // Predicted samples are never sent; numbering them would read as loss on the Mac.
      kind: kind, sequence: flags.contains(.predicted) ? sequence : nextSequence(),
      timestamp: timestamp(touch),
      x: normalized.x, y: normalized.y, pressure: normalized.pressure,
      altitude: normalized.altitude, azimuth: normalized.azimuth,
      buttons: buttons, flags: flags
    )
    publish(sample)
    if !hud.isHidden, kind == .down || kind == .move, !flags.contains(.predicted) {
      inkPoints.append((point, touch.timestamp))
      let cutoff = touch.timestamp - Self.traceLifetime
      inkPoints.removeAll { $0.time < cutoff }
      hud.updateTrace(inkPoints.map(\.point))
    }
  }

  private func publish(_ sample: PenSample) {
    if !panelOpen && !sample.flags.contains(.predicted) {
      sink.send(sample)
    }
    lastSample = sample
    guard !hud.isHidden else { return }
    if !sample.flags.contains(.predicted) {
      let now = CACurrentMediaTime()
      sampleTimes.append(now)
      sampleTimes.removeAll { $0 < now - 1 }
    }
    hud.update(sample, rate: sampleTimes.count, linkState: sink.linkState)
  }

  private func scheduleProximityExit() {
    pendingProximityExit?.cancel()
    pendingProximityExit = Task { [weak self] in
      try? await Task.sleep(for: Self.proximityExitDelay)
      guard !Task.isCancelled, let self, !self.isTouching else { return }
      self.publish(
        PenSample(
          kind: .proximityExit, sequence: self.nextSequence(), timestamp: self.timestamp(),
          x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, buttons: self.buttons
        ))
    }
  }

  private func cancelProximityExit() {
    pendingProximityExit?.cancel()
    pendingProximityExit = nil
  }

  private func timestamp(_ touch: UITouch) -> UInt64 {
    UInt64(max(0, touch.timestamp) * 1_000_000_000)
  }

  private func nextSequence() -> UInt32 {
    defer { sequence &+= 1 }
    return sequence
  }

  @available(iOS 16.0, *)
  @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
    let point = recognizer.location(in: self)
    let state = recognizer.state
    if state == .ended || state == .cancelled {
      if !isTouching { scheduleProximityExit() }
      return
    }
    // A hover sample during contact would lift the pen on the Mac mid-stroke.
    guard !isTouching else { return }
    cancelProximityExit()
    let zOffset = recognizer.zOffset
    let normalized = PencilNormalizer.normalize(
      location: SIMD2(Float(point.x), Float(point.y)),
      viewSize: SIMD2(Float(bounds.width), Float(bounds.height)), force: 0,
      maximumPossibleForce: 1, altitude: Float(recognizer.altitudeAngle),
      azimuth: Float(recognizer.azimuthAngle(in: self)), hoverZOffset: Float(zOffset)
    )
    let sample = PenSample(
      kind: .hover, sequence: nextSequence(), timestamp: timestamp(),
      x: normalized.x, y: normalized.y, pressure: 0, altitude: normalized.altitude,
      azimuth: normalized.azimuth, hoverDistance: normalized.hoverDistance, buttons: buttons
    )
    publish(sample)
  }

  private func timestamp() -> UInt64 {
    UInt64(CACurrentMediaTime() * 1_000_000_000)
  }
}

@MainActor
final class PenHUDView: UIView {
  private let pressure = UIProgressView(progressViewStyle: .default)
  private let values = UILabel()
  private let trace = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    pressure.tintColor = .systemBlue
    pressure.trackTintColor = .darkGray
    values.textColor = .white
    values.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    values.numberOfLines = 0
    layer.addSublayer(trace)
    addSubview(pressure)
    addSubview(values)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    pressure.frame = CGRect(x: 24, y: 32, width: bounds.width - 48, height: 4)
    values.frame = CGRect(x: 24, y: 44, width: bounds.width - 48, height: 100)
    trace.frame = bounds
  }

  func update(_ sample: PenSample, rate: Int, linkState: String = "") {
    pressure.progress = sample.pressure
    values.text = String(
      format: "link %@\npressure %.3f\naltitude %.3f  azimuth %.3f\nhover %u  %d Hz",
      linkState, sample.pressure, sample.altitude, sample.azimuth, sample.hoverDistance, rate
    )
  }

  func updateTrace(_ points: [CGPoint]) {
    guard let first = points.first else { return }
    let path = UIBezierPath()
    path.move(to: first)
    for point in points.dropFirst() { path.addLine(to: point) }
    trace.path = path.cgPath
    trace.strokeColor = UIColor.white.withAlphaComponent(0.5).cgColor
    trace.fillColor = UIColor.clear.cgColor
    trace.lineWidth = 1
  }

  func clearTrace() { trace.path = nil }
}

struct PenCaptureRepresentable: UIViewRepresentable {
  let sink: PenSampleSink
  @Binding var panelOpen: Bool
  @Binding var showsHUD: Bool

  func makeUIView(context: Context) -> PenCaptureView {
    let view = PenCaptureView(sink: sink)
    view.onPanelToggle = { panelOpen.toggle() }
    return view
  }

  func updateUIView(_ uiView: PenCaptureView, context: Context) {
    uiView.setPanelOpen(panelOpen)
    uiView.setHUDVisible(showsHUD)
  }
}
