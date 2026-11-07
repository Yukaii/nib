import NibCore
import UIKit

@MainActor
protocol GestureSink: AnyObject {
  func send(_ gesture: Gesture)
  var padSettings: PadSettings { get }
  var activeProfile: PadSettings.Profile { get }
  var hostInfo: ControlMessage.HostInfo? { get }
}

/// Owns UIKit recognizers so the capture view only reports Pencil contact state.
@MainActor
final class FingerGestureController: NSObject, UIGestureRecognizerDelegate {
  private weak var view: UIView?
  private let send: (Gesture) -> Void
  private let profile: () -> PadSettings.Profile
  private let hostInfo: () -> ControlMessage.HostInfo?
  private var palm = GesturePalmRejection()
  private let edgeControlContains: (CGPoint) -> Bool
  // A gesture that began must always end on the Mac, even if palm rejection
  // or a settings change would now suppress it; otherwise apps see a scroll
  // that never finishes.
  private var scrollActive = false
  private var zoomActive = false
  private var rotateActive = false
  private var arbiter = TwoFingerArbiter()
  private var suppressed = false
  private let pan: UIPanGestureRecognizer
  private let pinch: UIPinchGestureRecognizer
  private let rotation: UIRotationGestureRecognizer
  private let undoTap: UITapGestureRecognizer
  private let redoTap: UITapGestureRecognizer

  init(
    view: UIView, send: @escaping (Gesture) -> Void,
    profile: @escaping () -> PadSettings.Profile = { PadSettings().profile(forAppID: "") },
    hostInfo: @escaping () -> ControlMessage.HostInfo? = { nil },
    edgeControlContains: @escaping (CGPoint) -> Bool = { _ in false }
  ) {
    self.view = view
    self.send = send
    self.profile = profile
    self.hostInfo = hostInfo
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
    case .primary: return .primary
    case .alt: return .alt
    case .control: return .control
    }
  }

  private func sendZoom(_ delta: Double, phase: Gesture.Phase, profile: PadSettings.Profile) {
    send(
      .zoom(
        scaleDelta: delta, phase: phase, modifier: modifier(for: profile.gestures.zoomModifier),
        method: GestureCapabilityPolicy.zoomMethod(profile.gestures.zoomMethod, host: hostInfo())))
  }

  // The three recognizers only measure; `TwoFingerArbiter` decides what the
  // gesture means, and only that is sent (see its doc comment).

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    guard recognizer.state == .changed else { return finishIfIdle(recognizer) }
    let translation = recognizer.translation(in: view)
    recognizer.setTranslation(.zero, in: view)
    update(dx: translation.x, dy: translation.y)
  }

  @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
    guard recognizer.state == .changed else { return finishIfIdle(recognizer) }
    // UIKit's scale is cumulative since the pinch began; use per-event factors.
    let factor = recognizer.scale
    recognizer.scale = 1
    update(scale: factor)
  }

  @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
    guard recognizer.state == .changed else { return finishIfIdle(recognizer) }
    let radians = recognizer.rotation
    recognizer.rotation = 0
    // UIKit's rotation is clockwise-positive (y points down); AppKit's is
    // counter-clockwise-positive, so the sign flips on the way to the Mac.
    update(rotationDegrees: -Double(radians * 180 / .pi))
  }

  private func update(dx: Double = 0, dy: Double = 0, scale: Double = 1, rotationDegrees: Double = 0) {
    let current = profile()
    if arbiter.mode == .undecided && !scrollActive && !zoomActive && !rotateActive {
      suppressed = palm.suppresses(at: CACurrentMediaTime())
      arbiter.panEnabled = current.gestures.twoFingerScroll
      arbiter.zoomEnabled = current.gestures.pinchZoom
      arbiter.rotateEnabled = GestureCapabilityPolicy.rotateEnabled(current.gestures.rotate, host: hostInfo())
    }
    if suppressed || palm.suppresses(at: CACurrentMediaTime()) {
      suppressed = true
      endAll(.cancelled)
      return
    }
    arbiter.add(dx: dx, dy: dy, scale: scale, rotationDegrees: rotationDegrees)

    switch arbiter.mode {
    case .undecided:
      return
    case .pan:
      if !scrollActive {
        scrollActive = true
        send(.scroll(dx: 0, dy: 0, phase: .began))
        // Catch up the movement made while undecided.
        send(.scroll(dx: arbiter.translationX, dy: arbiter.translationY, phase: .changed))
      } else if dx != 0 || dy != 0 {
        send(.scroll(dx: dx, dy: dy, phase: .changed))
      }
    case .transform:
      if scrollActive {
        scrollActive = false
        send(.scroll(dx: 0, dy: 0, phase: .ended))
      }
      if arbiter.zoomEngaged {
        if !zoomActive {
          zoomActive = true
          sendZoom(1, phase: .began, profile: current)
          sendZoom(exp(arbiter.logScale), phase: .changed, profile: current)
        } else if scale != 1 {
          sendZoom(scale, phase: .changed, profile: current)
        }
      }
      if arbiter.rotateEngaged {
        if !rotateActive {
          rotateActive = true
          send(.rotate(degreesDelta: 0, phase: .began))
          send(.rotate(degreesDelta: arbiter.rotationDegrees, phase: .changed))
        } else if rotationDegrees != 0 {
          send(.rotate(degreesDelta: rotationDegrees, phase: .changed))
        }
      }
    }
  }

  /// Ends the gesture once none of the three recognizers is still tracking.
  private func finishIfIdle(_ recognizer: UIGestureRecognizer) {
    let tracking: (UIGestureRecognizer) -> Bool = { $0.state == .began || $0.state == .changed }
    guard [pan, pinch, rotation].allSatisfy({ $0 === recognizer || !tracking($0) }),
      recognizer.state != .began
    else { return }
    endAll(recognizer.state == .ended ? .ended : .cancelled)
    arbiter.reset()
    suppressed = false
  }

  private func endAll(_ phase: Gesture.Phase) {
    let current = profile()
    if scrollActive {
      scrollActive = false
      send(.scroll(dx: 0, dy: 0, phase: phase))
    }
    if zoomActive {
      zoomActive = false
      sendZoom(1, phase: phase, profile: current)
    }
    if rotateActive {
      rotateActive = false
      send(.rotate(degreesDelta: 0, phase: phase))
    }
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
