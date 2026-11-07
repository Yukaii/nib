import NibCore
import UIKit

@MainActor
final class EdgeControlsView: UIView {
  enum Route: Equatable {
    case button(Int)
    case strip
  }
  private let profile: () -> PadSettings.Profile
  private let hostInfo: () -> ControlMessage.HostInfo?
  private let send: (Gesture) -> Void
  private var renderedProfile: PadSettings.Profile?
  private var buttons: [ShortcutButtonView] = []
  private let stripView: EdgeStripView
  private var holds = ActiveHoldTracker()
  private var holdIDs: [ObjectIdentifier: UUID] = [:]
  private var activeTouchIDs: Set<ObjectIdentifier> = []
  var hasVisibleControls: Bool { !buttons.isEmpty || !stripView.isHidden }

  init(
    profile: @escaping () -> PadSettings.Profile,
    hostInfo: @escaping () -> ControlMessage.HostInfo? = { nil },
    send: @escaping (Gesture) -> Void
  ) {
    self.profile = profile
    self.hostInfo = hostInfo
    self.send = send
    stripView = EdgeStripView(profile: profile, hostInfo: hostInfo, send: send)
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    stripView.isUserInteractionEnabled = false
    addSubview(stripView)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    refresh()
    let current = profile()
    let width: CGFloat = current.strip.mode == .off ? 0 : 44
    let x = current.strip.side == .left ? 0 : bounds.width - width
    stripView.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
    stripView.isHidden = current.strip.mode == .off
    let buttonX = current.strip.side == .left ? bounds.width - 72 : 0
    let height: CGFloat = 64
    let gap: CGFloat = 8
    let total = CGFloat(buttons.count) * height + CGFloat(max(0, buttons.count - 1)) * gap
    var y = max(0, (bounds.height - total) / 2)
    for button in buttons {
      button.frame = CGRect(x: buttonX, y: y, width: 72, height: height)
      y += height + gap
    }
  }

  func route(at point: CGPoint) -> Route? {
    if let index = buttons.firstIndex(where: { $0.frame.contains(point) }) { return .button(index) }
    if !stripView.isHidden && stripView.frame.contains(point) { return .strip }
    return nil
  }
  func containsControl(at point: CGPoint) -> Bool { route(at: point) != nil }

  func touchBegan(_ route: Route, touchID: ObjectIdentifier, point: CGPoint) {
    activeTouchIDs.insert(touchID)
    switch route {
    case .button(let index):
      guard buttons.indices.contains(index) else { return }
      let button = buttons[index]
      button.setPressed(true)
      button.press()
      if button.shortcut.hold {
        let holdID = UUID()
        holdIDs[touchID] = holdID
        holds.begin(id: holdID, chord: button.shortcut.chord)
        send(.key(button.shortcut.chord, action: .down))
      }
    case .strip: stripView.begin(at: point)
    }
  }
  func touchMoved(_ route: Route, point: CGPoint) { if case .strip = route { stripView.move(to: point) } }
  func touchEnded(_ route: Route, touchID: ObjectIdentifier, cancelled: Bool) {
    guard activeTouchIDs.remove(touchID) != nil else { return }
    switch route {
    case .button(let index):
      guard buttons.indices.contains(index) else {
        if let holdID = holdIDs.removeValue(forKey: touchID) { _ = holds.end(id: holdID) }
        return
      }
      let button = buttons[index]
      button.setPressed(false)
      if button.shortcut.hold {
        if let holdID = holdIDs.removeValue(forKey: touchID), let gesture = holds.end(id: holdID) {
          send(gesture)
        }
      } else if !cancelled {
        send(.key(button.shortcut.chord, action: .tap))
      }
    case .strip: stripView.end(cancelled: cancelled)
    }
  }
  func releaseAll() {
    for gesture in holds.releaseAll() { send(gesture) }
    holdIDs.removeAll()
    activeTouchIDs.removeAll()
    for button in buttons { button.setPressed(false) }
    stripView.cancel()
  }
  func refresh() {
    let current = profile()
    guard renderedProfile != current else { return }
    releaseAll()
    renderedProfile = current
    for button in buttons { button.removeFromSuperview() }
    buttons = current.buttons.map { button in
      let view = ShortcutButtonView(button: button)
      addSubview(view)
      return view
    }
    stripView.updateProfile(current)
    setNeedsLayout()
  }
}

@MainActor
private final class ShortcutButtonView: UIButton {
  let shortcut: PadSettings.ShortcutButton
  private let haptic = UIImpactFeedbackGenerator(style: .light)
  init(button: PadSettings.ShortcutButton) {
    shortcut = button
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    setTitle(button.label, for: .normal)
    setTitleColor(.white.withAlphaComponent(0.25), for: .normal)
    titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    layer.borderColor = UIColor.darkGray.withAlphaComponent(0.8).cgColor
    layer.borderWidth = 1
    layer.cornerRadius = 8
    backgroundColor = .clear
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func press() { haptic.impactOccurred() }
  func setPressed(_ value: Bool) { backgroundColor = value ? UIColor.white.withAlphaComponent(0.12) : .clear }
}

@MainActor
private final class EdgeStripView: UIView {
  private let profile: () -> PadSettings.Profile
  private let hostInfo: () -> ControlMessage.HostInfo?
  private let send: (Gesture) -> Void
  private var activeMode: PadSettings.StripMode = .off
  private var lastY: CGFloat = 0
  private var stepper = StripStepper()
  init(
    profile: @escaping () -> PadSettings.Profile,
    hostInfo: @escaping () -> ControlMessage.HostInfo? = { nil },
    send: @escaping (Gesture) -> Void
  ) {
    self.profile = profile
    self.hostInfo = hostInfo
    self.send = send
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    layer.borderColor = UIColor.darkGray.withAlphaComponent(0.8).cgColor
    layer.borderWidth = 1
    layer.cornerRadius = 8
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func updateProfile(_ profile: PadSettings.Profile) { isHidden = profile.strip.mode == .off }
  func begin(at point: CGPoint) {
    activeMode = profile().strip.mode
    guard activeMode != .off else { return }
    lastY = point.y
    stepper.end()
    switch activeMode {
    case .scroll: send(.scroll(dx: 0, dy: 0, phase: .began))
    case .zoom:
      send(
        .zoom(
          scaleDelta: 1, phase: .began, modifier: zoomModifier(profile().gestures.zoomModifier),
          method: zoomMethod(profile().gestures.zoomMethod)))
    case .brushSize, .off: break
    }
  }
  func move(to point: CGPoint) {
    guard activeMode != .off else { return }
    let delta = point.y - lastY
    lastY = point.y
    switch activeMode {
    case .scroll: send(.scroll(dx: 0, dy: delta, phase: .changed))
    case .zoom:
      send(
        .zoom(
          scaleDelta: pow(2, Double(-delta / 240)), phase: .changed,
          modifier: zoomModifier(profile().gestures.zoomModifier),
          method: zoomMethod(profile().gestures.zoomMethod)))
    case .brushSize:
      let count = stepper.add(Double(-delta))
      guard count != 0 else { return }
      let chord = Gesture.KeyChord(key: count > 0 ? "BracketRight" : "BracketLeft")
      for _ in 0..<abs(count) { send(.key(chord, action: .tap)) }
    case .off: break
    }
  }
  func end(cancelled: Bool) {
    switch activeMode {
    case .scroll: send(.scroll(dx: 0, dy: 0, phase: cancelled ? .cancelled : .ended))
    case .zoom:
      send(
        .zoom(
          scaleDelta: 1, phase: cancelled ? .cancelled : .ended,
          modifier: zoomModifier(profile().gestures.zoomModifier),
          method: zoomMethod(profile().gestures.zoomMethod)))
    case .brushSize, .off: break
    }
    stepper.end()
    activeMode = .off
  }
  func cancel() { if activeMode != .off { end(cancelled: true) } }
  private func zoomModifier(_ modifier: PadSettings.ZoomModifier) -> Gesture.Modifier {
    switch modifier {
    case .primary: .primary
    case .alt: .alt
    case .control: .control
    }
  }
  private func zoomMethod(_ method: PadSettings.ZoomMethod) -> Gesture.ZoomMethod {
    GestureCapabilityPolicy.zoomMethod(method, host: hostInfo())
  }
}
