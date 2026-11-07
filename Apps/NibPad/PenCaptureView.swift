import NibCore
import SwiftUI
import UIKit

@MainActor
protocol PenSampleSink: AnyObject {
  func send(_ sample: PenSample)
}

@MainActor
final class LoggingSink: PenSampleSink {
  private(set) var latestSample: PenSample?
  func send(_ sample: PenSample) { latestSample = sample }
}

@MainActor
final class PenCaptureView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
  let sink: PenSampleSink
  private var sequence: UInt32 = 0
  private var buttons: PenSample.Buttons = []
  private var wasActive = false
  private var originalBrightness: CGFloat?
  private let hud = PenHUDView()
  private var hoverRecognizer: UIHoverGestureRecognizer?
  private var lastSample: PenSample?
  private var inkPoints: [CGPoint] = []

  init(sink: PenSampleSink = LoggingSink()) {
    self.sink = sink
    super.init(frame: .zero)
    isMultipleTouchEnabled = true
    backgroundColor = .black
    addSubview(hud)
    hud.isHidden = true
    let hudTap = UITapGestureRecognizer(target: self, action: #selector(toggleHUD))
    hudTap.numberOfTouchesRequired = 3
    hudTap.delegate = self
    addGestureRecognizer(hudTap)
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
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    hud.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { activateScreenOffMode() } else { restoreScreen() }
  }

  @objc private func willResignActive() { restoreScreen() }

  private func activateScreenOffMode() {
    guard !wasActive else { return }
    wasActive = true
    originalBrightness = UIScreen.main.brightness
    UIScreen.main.brightness = 0.0
    UIApplication.shared.isIdleTimerDisabled = true
  }

  private func restoreScreen() {
    guard wasActive else { return }
    wasActive = false
    UIApplication.shared.isIdleTimerDisabled = false
    if let originalBrightness { UIScreen.main.brightness = originalBrightness }
    self.originalBrightness = nil
  }

  @objc private func toggleHUD() {
    hud.isHidden.toggle()
    if hud.isHidden {
      inkPoints.removeAll()
      hud.clearTrace()
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
      kind: kind, sequence: nextSequence(), timestamp: timestamp(touch),
      x: normalized.x, y: normalized.y, pressure: normalized.pressure,
      altitude: normalized.altitude, azimuth: normalized.azimuth,
      buttons: buttons, flags: flags
    )
    sink.send(sample)
    lastSample = sample
    hud.update(sample)
    if kind == .down || kind == .move {
      inkPoints.append(point)
      hud.updateTrace(inkPoints)
    }
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
      let exit = PenSample(
        kind: .proximityExit, sequence: nextSequence(), timestamp: timestamp(),
        x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, buttons: buttons
      )
      sink.send(exit)
      lastSample = exit
      hud.update(exit)
      return
    }
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
    sink.send(sample)
    lastSample = sample
    hud.update(sample)
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

  func update(_ sample: PenSample) {
    pressure.progress = sample.pressure
    values.text = String(
      format: "pressure %.3f\naltitude %.3f  azimuth %.3f\nhover %u  %.0f Hz",
      sample.pressure, sample.altitude, sample.azimuth, sample.hoverDistance, 0
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
  func makeUIView(context: Context) -> PenCaptureView { PenCaptureView(sink: sink) }
  func updateUIView(_ uiView: PenCaptureView, context: Context) {}
}
