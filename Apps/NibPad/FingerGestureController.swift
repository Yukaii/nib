import NibCore
import UIKit

@MainActor
protocol GestureSink: AnyObject {
  func send(_ gesture: Gesture)
  var padSettings: PadSettings { get }
}

/// Owns UIKit recognizers so the capture view only reports Pencil contact state.
@MainActor
final class FingerGestureController: NSObject, UIGestureRecognizerDelegate {
  private weak var view: UIView?
  private let send: (Gesture) -> Void
  private let settings: () -> PadSettings
  private var palm = GesturePalmRejection()
  // A gesture that began must always end on the Mac, even if palm rejection
  // or a settings change would now suppress it; otherwise apps see a scroll
  // that never finishes.
  private var panActive = false
  private var pinchActive = false
  private let pan: UIPanGestureRecognizer
  private let pinch: UIPinchGestureRecognizer
  private let undoTap: UITapGestureRecognizer
  private let redoTap: UITapGestureRecognizer

  init(
    view: UIView, send: @escaping (Gesture) -> Void, settings: @escaping () -> PadSettings = { PadSettings() }
  ) {
    self.view = view
    self.send = send
    self.settings = settings
    pan = UIPanGestureRecognizer()
    pinch = UIPinchGestureRecognizer()
    undoTap = UITapGestureRecognizer()
    redoTap = UITapGestureRecognizer()
    super.init()

    pan.minimumNumberOfTouches = 2
    pan.maximumNumberOfTouches = 2
    undoTap.numberOfTouchesRequired = 2
    redoTap.numberOfTouchesRequired = 3
    for recognizer in [pan, pinch, undoTap, redoTap] {
      recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      recognizer.delegate = self
      view.addGestureRecognizer(recognizer)
    }
    pan.addTarget(self, action: #selector(handlePan(_:)))
    pinch.addTarget(self, action: #selector(handlePinch(_:)))
    undoTap.addTarget(self, action: #selector(handleUndo(_:)))
    redoTap.addTarget(self, action: #selector(handleRedo(_:)))
  }

  func pencilBegan() { palm.pencilBegan() }
  func pencilEnded() { palm.pencilEnded(at: CACurrentMediaTime()) }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    touch.type == .direct
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    (gestureRecognizer === pan && otherGestureRecognizer === pinch)
      || (gestureRecognizer === pinch && otherGestureRecognizer === pan)
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

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    let finishing =
      recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
    if finishing && panActive {
      panActive = false
      send(.scroll(dx: 0, dy: 0, phase: recognizer.state == .ended ? .ended : .cancelled))
      return
    }
    guard allowed(settings().gestures.twoFingerScroll) else {
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
    let modifierValue = modifier(for: settings().gestures.zoomModifier)
    let finishing =
      recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
    if finishing && pinchActive {
      pinchActive = false
      send(
        .zoom(scaleDelta: 1, phase: recognizer.state == .ended ? .ended : .cancelled, modifier: modifierValue)
      )
      return
    }
    guard allowed(settings().gestures.pinchZoom) else {
      if pinchActive {
        pinchActive = false
        send(.zoom(scaleDelta: 1, phase: .cancelled, modifier: modifierValue))
      }
      return
    }
    if recognizer.state == .began || (recognizer.state == .changed && !pinchActive) {
      pinchActive = true
      recognizer.scale = 1
      send(.zoom(scaleDelta: 1, phase: .began, modifier: modifierValue))
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
    send(.zoom(scaleDelta: delta, phase: phase, modifier: modifierValue))
  }

  @objc private func handleUndo(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, allowed(settings().gestures.tapUndoRedo) else { return }
    send(.undo)
  }

  @objc private func handleRedo(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended, allowed(settings().gestures.tapUndoRedo) else { return }
    send(.redo)
  }
}
