import NibCore
import UIKit

@MainActor
final class EdgeControlsView: UIView {
  private let profile: () -> PadSettings.Profile
  private let send: (Gesture) -> Void
  private var renderedProfile: PadSettings.Profile?
  private var buttons: [UIButton] = []
  private let stripView: EdgeStripView

  var hasVisibleControls: Bool {
    !buttons.isEmpty || !stripView.isHidden
  }

  init(profile: @escaping () -> PadSettings.Profile, send: @escaping (Gesture) -> Void) {
    self.profile = profile
    self.send = send
    stripView = EdgeStripView(profile: profile, send: send)
    super.init(frame: .zero)
    isUserInteractionEnabled = true
    addSubview(stripView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    refresh()
    let current = profile()
    let stripWidth: CGFloat = current.strip.mode == .off ? 0 : 44
    let stripX = current.strip.side == .left ? 0 : bounds.width - stripWidth
    stripView.frame = CGRect(x: stripX, y: 0, width: stripWidth, height: bounds.height)
    stripView.isHidden = current.strip.mode == .off

    let buttonSide = current.strip.side == .left ? bounds.width - 72 : 0
    let height: CGFloat = 64
    let gap: CGFloat = 8
    let total = CGFloat(buttons.count) * height + CGFloat(max(0, buttons.count - 1)) * gap
    var y = max(0, (bounds.height - total) / 2)
    for button in buttons {
      button.frame = CGRect(x: buttonSide, y: y, width: 72, height: height)
      y += height + gap
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    refresh()
    layoutIfNeeded()
    guard event?.allTouches?.contains(where: { $0.type == .direct }) == true else { return nil }
    for button in buttons {
      if button.frame.contains(point) { return button.hitTest(convert(point, to: button), with: event) }
    }
    if !stripView.isHidden, stripView.frame.contains(point) {
      return stripView.hitTest(convert(point, to: stripView), with: event)
    }
    return nil
  }

  func containsControl(at point: CGPoint) -> Bool {
    refresh()
    layoutIfNeeded()
    return buttons.contains(where: { $0.frame.contains(point) })
      || (!stripView.isHidden && stripView.frame.contains(point))
  }

  func refresh() {
    let current = profile()
    guard renderedProfile != current else { return }
    renderedProfile = current
    for button in buttons { button.removeFromSuperview() }
    buttons = current.buttons.map { button in
      let view = ShortcutButtonView(button: button, send: send)
      addSubview(view)
      return view
    }
    stripView.updateProfile(current)
    setNeedsLayout()
  }
}

@MainActor
private final class ShortcutButtonView: UIButton {
  private let shortcut: PadSettings.ShortcutButton
  private let send: (Gesture) -> Void
  private let haptic = UIImpactFeedbackGenerator(style: .light)
  private var sentDown = false

  init(button: PadSettings.ShortcutButton, send: @escaping (Gesture) -> Void) {
    shortcut = button
    self.send = send
    super.init(frame: .zero)
    setTitle(button.label, for: .normal)
    setTitleColor(.white.withAlphaComponent(0.25), for: .normal)
    titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    layer.borderColor = UIColor.darkGray.withAlphaComponent(0.8).cgColor
    layer.borderWidth = 1
    layer.cornerRadius = 8
    backgroundColor = .clear
    addTarget(self, action: #selector(touchDown), for: .touchDown)
    addTarget(self, action: #selector(touchUpInside), for: .touchUpInside)
    addTarget(self, action: #selector(touchUpOutside), for: [.touchUpOutside, .touchCancel])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func touchDown() {
    haptic.impactOccurred()
    guard shortcut.hold else { return }
    sentDown = true
    if let gesture = ShortcutButtonGestureMapper.gesture(for: shortcut, event: .down) { send(gesture) }
  }

  @objc private func touchUpInside() {
    if shortcut.hold {
      finishHold()
    } else if let gesture = ShortcutButtonGestureMapper.gesture(for: shortcut, event: .up) {
      send(gesture)
    }
  }

  @objc private func touchUpOutside() {
    if shortcut.hold { finishHold() }
  }

  private func finishHold() {
    guard sentDown else { return }
    sentDown = false
    if let gesture = ShortcutButtonGestureMapper.gesture(for: shortcut, event: .up) { send(gesture) }
  }
}

@MainActor
private final class EdgeStripView: UIView {
  private let profile: () -> PadSettings.Profile
  private let send: (Gesture) -> Void
  private var activeMode: PadSettings.StripMode = .off
  private var lastY: CGFloat = 0
  private var stepper = StripStepper()

  init(profile: @escaping () -> PadSettings.Profile, send: @escaping (Gesture) -> Void) {
    self.profile = profile
    self.send = send
    super.init(frame: .zero)
    isMultipleTouchEnabled = false
    backgroundColor = .clear
    layer.borderColor = UIColor.darkGray.withAlphaComponent(0.8).cgColor
    layer.borderWidth = 1
    layer.cornerRadius = 8
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func updateProfile(_ profile: PadSettings.Profile) {
    isHidden = profile.strip.mode == .off
    layer.borderColor = UIColor.darkGray.withAlphaComponent(0.8).cgColor
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, touch.type == .direct else { return }
    activeMode = profile().strip.mode
    guard activeMode != .off else { return }
    lastY = touch.location(in: self).y
    stepper.end()
    switch activeMode {
    case .scroll: send(.scroll(dx: 0, dy: 0, phase: .began))
    case .zoom:
      send(.zoom(scaleDelta: 1, phase: .began, modifier: zoomModifier(profile().gestures.zoomModifier)))
    case .brushSize, .off: break
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, touch.type == .direct else { return }
    let y = touch.location(in: self).y
    let deltaY = y - lastY
    lastY = y
    switch activeMode {
    case .scroll: send(.scroll(dx: 0, dy: deltaY, phase: .changed))
    case .zoom:
      let scale = pow(2, Double(-deltaY / 240))
      send(.zoom(scaleDelta: scale, phase: .changed, modifier: zoomModifier(profile().gestures.zoomModifier)))
    case .brushSize:
      let count = stepper.add(Double(-deltaY))
      sendBrushSteps(count)
    case .off: break
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(.ended) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(.cancelled) }

  private func finish(_ phase: Gesture.Phase) {
    switch activeMode {
    case .scroll: send(.scroll(dx: 0, dy: 0, phase: phase))
    case .zoom:
      send(.zoom(scaleDelta: 1, phase: phase, modifier: zoomModifier(profile().gestures.zoomModifier)))
    case .brushSize, .off: break
    }
    stepper.end()
    activeMode = .off
  }

  private func sendBrushSteps(_ count: Int) {
    guard count != 0 else { return }
    let chord = Gesture.KeyChord(keyCode: count > 0 ? 30 : 33)
    for _ in 0..<abs(count) { send(.key(chord, action: .tap)) }
  }

  private func zoomModifier(_ modifier: PadSettings.ZoomModifier) -> Gesture.Modifier {
    switch modifier {
    case .command: .command
    case .option: .option
    case .control: .control
    }
  }
}
