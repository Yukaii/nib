import NibCore
import UIKit

@MainActor
protocol GestureSink: AnyObject {
  func send(_ gesture: Gesture)
  var padSettings: PadSettings { get }
  var activeProfile: PadSettings.Profile { get }
}

/// Owns UIKit recognizers so the capture view only reports Pencil contact state.
@MainActor
final class FingerGestureController: NSObject, UIGestureRecognizerDelegate {
  private weak var view: UIView?
  private let send: (Gesture) -> Void
  private let profile: () -> PadSettings.Profile
  private var palm = GesturePalmRejection()
  private let edgeControlContains: (CGPoint) -> Bool
  // A gesture that began must always end on the Mac, even if palm rejection
  // or a settings change would now suppress it; otherwise apps see a scroll
  // that never finishes.
  private var panActive = false
  private var pinchActive = false
  private var rotationActive = false
  private var rotationTotal: CGFloat = 0
  private let pan: UIPanGestureRecognizer
  private let pinch: UIPinchGestureRecognizer
  private let rotation: UIRotationGestureRecognizer
  private let undoTap: UITapGestureRecognizer
  private let redoTap: UITapGestureRecognizer

  init(
    view: UIView, send: @escaping (Gesture) -> Void,
    profile: @escaping () -> PadSettings.Profile = { PadSettings().profile(forBundleID: "") },
    edgeControlContains: @escaping (CGPoint) -> Bool = { _ in false }
  ) {
    self.view = view
    self.send = send
    self.profile = profile
    self.edgeControlContains = edgeControlContains
    pan = UIPanGestureRecognizer()
    pinch = UIPinchGestureRecognizer()
    rotation = UIRotationGestureRecognizer()
    undoTap = UITapGestureRecognizer()
    redoTap = UITapGestureRecognizer()
    super.init()

    pan.minimumNumberOfTouches = 2
    pan.maximumNumberOfTouches = 2
    undoTap.numberOfTouchesRequired = 2
    redoTap.numberOfTouchesRequired = 3
    for recognizer in [pan, pinch, rotation, undoTap, redoTap] {
      recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      recognizer.delegate = self
      view.addGestureRecognizer(recognizer)
    }
    pan.addTarget(self, action: #selector(handlePan(_:)))
    pinch.addTarget(self, action: #selector(handlePinch(_:)))
    rotation.addTarget(self, action: #selector(handleRotation(_:)))
    undoTap.addTarget(self, action: #selector(handleUndo(_:)))
    redoTap.addTarget(self, action: #selector(handleRedo(_:)))
  }

  func pencilBegan() { palm.pencilBegan() }
  func pencilEnded() { palm.pencilEnded(at: CACurrentMediaTime()) }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    touch.type == .direct && !edgeControlContains(touch.location(in: view))
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    [pan, pinch, rotation].contains(gestureRecognizer)
      && [pan, pinch, rotation].contains(otherGestureRecognizer)
  }

  private func allowed(_ enabled: Bool) -> Bool {
    enabled && !palm.suppresses(at: CACurrentMediaTime())
  }

  private func modifier(for value: PadSettings.ZoomModifier) -> Gesture.Modifier {
    switch value {
    case .command: return .command
    case .option: return .option
    case .control: return .control
    }
  }

  private func zoomMethod(_ value: PadSettings.ZoomMethod) -> Gesture.ZoomMethod {
    value == .nativeGesture ? .nativeGesture : .modifierScroll
  }

  private func sendZoom(_ delta: Double, phase: Gesture.Phase, profile: PadSettings.Profile) {
    send(
      .zoom(
        scaleDelta: delta, phase: phase, modifier: modifier(for: profile.gestures.zoomModifier),
        method: zoomMethod(profile.gestures.zoomMethod)))
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    let finishing =
      recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
    if finishing && panActive {
      panActive = false
      send(.scroll(dx: 0, dy: 0, phase: recognizer.state == .ended ? .ended : .cancelled))
      return
    }
    guard allowed(profile().gestures.twoFingerScroll) else {
      if panActive {
        panActive = false
        send(.scroll(dx: 0, dy: 0, phase: .cancelled))
      }
      return
    }
    if recognizer.state == .began || (recognizer.state == .changed && !panActive) {
      panActive = true
      recognizer.setTranslation(.zero, in: view)
      send(.scroll(dx: 0, dy: 0, phase: .began))
      return
    }
    guard recognizer.state == .changed else { return }
    let phase: Gesture.Phase
    switch recognizer.state {
    case .began: phase = .began
    case .changed: phase = .changed
    case .ended: phase = .ended
    case .cancelled, .failed: phase = .cancelled
    default: return
    }
    let translation = recognizer.translation(in: view)
    recognizer.setTranslation(.zero, in: view)
    send(.scroll(dx: translation.x, dy: translation.y, phase: phase))
  }

  @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
    let finishing =
      recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
    if finishing && pinchActive {
      pinchActive = false
      sendZoom(1, phase: recognizer.state == .ended ? .ended : .cancelled, profile: profile())
      return
    }
    guard allowed(profile().gestures.pinchZoom) else {
      if pinchActive {
        pinchActive = false
        sendZoom(1, phase: .cancelled, profile: profile())
      }
      return
    }
    if recognizer.state == .began || (recognizer.state == .changed && !pinchActive) {
      pinchActive = true
      recognizer.scale = 1
      sendZoom(1, phase: .began, profile: profile())
      return
    }
    guard recognizer.state == .changed else { return }
    let phase: Gesture.Phase
    switch recognizer.state {
    case .began: phase = .began
    case .changed: phase = .changed
    case .ended: phase = .ended
    case .cancelled, .failed: phase = .cancelled
    default: return
    }
    // UIKit's scale is cumulative since the pinch began; send per-event deltas.
    let delta = recognizer.scale
    recognizer.scale = 1
    sendZoom(delta, phase: phase, profile: profile())
  }

  @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
    let finishing =
      recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
    if finishing && rotationActive {
      rotationActive = false
      rotationTotal = 0
      send(.rotate(degreesDelta: 0, phase: recognizer.state == .ended ? .ended : .cancelled))
      return
    }
    guard allowed(profile().gestures.rotate) else {
      if rotationActive {
        rotationActive = false
        rotationTotal = 0
        send(.rotate(degreesDelta: 0, phase: .cancelled))
      }
      return
    }
    if recognizer.state == .began {
      rotationTotal = 0
      recognizer.rotation = 0
      return
    }
    guard recognizer.state == .changed else { return }
    let radians = recognizer.rotation
    recognizer.rotation = 0
    rotationTotal += radians
    guard abs(rotationTotal) > 8 * .pi / 180 else { return }
    if !rotationActive {
      rotationActive = true
      send(.rotate(degreesDelta: 0, phase: .began))
    }
    send(.rotate(degreesDelta: Double(radians * 180 / .pi), phase: .changed))
  }

  @objc private func handleUndo(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, allowed(profile().gestures.tapUndoRedo) else { return }
    send(.undo)
  }

  @objc private func handleRedo(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, allowed(profile().gestures.tapUndoRedo) else { return }
    send(.redo)
  }
}
