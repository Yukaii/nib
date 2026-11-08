import NibCore
import SwiftUI

struct ConnectionStatusOverlay: View {
  let linkState: PenLinkState
  let selectedHost: String?

  var body: some View {
    VStack(spacing: 8) {
      Text(message).font(.callout).foregroundStyle(.white.opacity(0.6))
      Text("Four-finger tap for settings").font(.caption).foregroundStyle(.white.opacity(0.4))
    }
    .multilineTextAlignment(.center)
    .allowsHitTesting(false)
  }

  private var message: String {
    linkState.userFacingText(selectedHost: selectedHost)
  }
}

struct PairingInstructionsView: View {
  let pairingCode: String?
  let pairingPeer: String?
  let pair: () -> Void
  let cancel: () -> Void
  let pairAgain: () -> Void
  let error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: "lock.shield").font(.system(size: 42)).foregroundStyle(.cyan)
      Text("Pair with \(pairingPeer ?? "your Mac")").font(.largeTitle.bold())
      Text(
        pairingCode.map { "Check that your Mac shows \($0)." }
          ?? "Start pairing on your iPad, then check the same code on both screens.")
      Text("Tap Pair on both devices when the six-digit codes match.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Button("Pair", action: pair).buttonStyle(.borderedProminent).tint(.cyan)
        Button("Not now", action: cancel).buttonStyle(.plain)
      }
      if pairingCode != nil {
        Text("Waiting for your confirmation…").foregroundStyle(.secondary)
      }
      if let error {
        Text(error).foregroundStyle(.orange)
        Button("Pair again", action: pairAgain).buttonStyle(.bordered)
      }
    }
    .padding(28)
    .foregroundStyle(.white)
    .frame(maxWidth: 520)
  }
}

struct OnboardingView: View {
  @Binding var step: Int
  let hosts: [String]
  let linkState: PenLinkState
  let pairingCode: String?
  let pairingPeer: String?
  let chooseMac: (String) -> Void
  let pair: () -> Void
  let cancelPairing: () -> Void
  let pairAgain: () -> Void
  let pairingError: String?
  let finish: (PressureCheckResult) -> Void
  @State private var localNetworkHint = false
  @State private var localPressureSamples: [Float] = []
  @State private var latestForce: CGFloat = 0
  @State private var latestMaximumForce: CGFloat = 0

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 24) {
        progress
        Group {
          switch step {
          case 0: welcome
          case 1: install
          case 2: choose
          case 3: pairing
          case 4: pressure
          case 5: gestures
          default: start
          }
        }
        .frame(maxWidth: 520)
        Spacer()
      }
      .padding(28)
      .foregroundStyle(.white)
    }
    .task(id: step) {
      localNetworkHint = false
      guard step == 2 else { return }
      try? await Task.sleep(for: .seconds(10))
      if hosts.isEmpty { localNetworkHint = true }
    }
  }

  private var progress: some View {
    HStack {
      Text("Nib").font(.title2.bold())
      Spacer()
      Text("Step \(min(step + 1, 7)) of 7").font(.caption).foregroundStyle(.secondary)
    }
  }

  private var welcome: some View {
    page(title: "Turn your iPad into a drawing tablet", symbol: "ipad.and.arrow.forward") {
      Text("Nib keeps the iPad screen dark while your Apple Pencil draws on your Mac.")
      button("Get started") { step = 1 }
    }
  }

  private var install: some View {
    page(title: "Install Nib on your Mac", symbol: "macbook.and.iphone") {
      Text(
        "Install and open Nib on the Mac you want to draw on. Keep both devices on the same Wi-Fi network, or connect them with a cable."
      )
      Link(
        "Open Mac installation instructions",
        destination: URL(string: "https://github.com/Yukaii/nib#install")!
      )
      .foregroundStyle(.cyan)
      button("Continue") { step = 2 }
    }
  }

  private var choose: some View {
    page(title: "Choose your Mac", symbol: "display.2") {
      if hosts.isEmpty {
        ProgressView("Looking for Macs…")
        if localNetworkHint {
          Text(
            "No Mac found yet. In Settings, allow Nib to find devices on your local network, then return here."
          )
          .font(.callout).foregroundStyle(.orange)
        }
      } else {
        ForEach(hosts, id: \.self) { host in
          Button {
            chooseMac(host)
            step = 3
          } label: {
            Label(host, systemImage: "display")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.borderedProminent)
        }
      }
      if case .rejected = linkState {
        Text(linkState.userFacingText()).foregroundStyle(.orange)
      }
      Button("I’ll choose later") { step = 3 }.buttonStyle(.plain).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var pairing: some View {
    if case .connected = linkState {
      // Already paired (e.g. intro reopened) or pairing just finished.
      page(title: "Paired", symbol: "checkmark.shield") {
        Text(linkState.userFacingText())
        button("Continue") { step = 4 }
      }
    } else {
      PairingInstructionsView(
        pairingCode: pairingCode, pairingPeer: pairingPeer, pair: pair,
        cancel: {
          cancelPairing()
          step = 2
        }, pairAgain: pairAgain, error: pairingError)
    }
  }

  private var pressure: some View {
    let result = PressureCheckClassifier.classify(localPressureSamples)
    return page(title: "Check your Apple Pencil", symbol: "pencil.tip") {
      Text("Press lightly, then firmly, on the iPad a few times. Nib needs pressure to reach drawing apps.")
      PressurePad { value, force, maximum in
        localPressureSamples.append(value)
        if localPressureSamples.count > 64 { localPressureSamples.removeFirst() }
        latestForce = force
        latestMaximumForce = maximum
      }
      .frame(height: 130)
      Text(
        String(
          format: "Force %.2f / maximum %.2f", Double(latestForce), Double(latestMaximumForce))
      )
      .font(.caption).foregroundStyle(.secondary)
      switch result {
      case .notEnoughData: Text("Waiting for a few Pencil strokes…").foregroundStyle(.secondary)
      case .ok: Label("Pressure is working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .noPressure:
        Text(
          "This Pencil doesn’t report pressure. Nib needs Apple Pencil (1st gen), Apple Pencil 2 or Apple Pencil Pro."
        )
        .foregroundStyle(.orange)
      }
      HStack {
        button("Continue") { step = 5 }
        if result == .notEnoughData { Button("Skip for now") { step = 5 }.buttonStyle(.plain) }
      }
    }
  }

  private var gestures: some View {
    page(title: "Useful gestures", symbol: "hand.draw") {
      gesture("hand.tap", "Four-finger tap", "Open settings")
      gesture("arrow.up.and.down", "Two-finger drag", "Scroll")
      gesture("arrow.up.left.and.arrow.down.right", "Pinch or twist", "Zoom or rotate")
      gesture("arrow.uturn.backward", "Two-finger tap", "Undo")
      gesture("arrow.uturn.forward", "Three-finger tap", "Redo")
      button("Continue") { step = 6 }
    }
  }

  private var start: some View {
    page(title: "Ready to draw", symbol: "scribble.variable") {
      Text(
        "The screen will go black. Put the Pencil on the iPad to draw on your Mac. Four-finger tap opens settings anytime."
      )
      button("Start drawing") {
        finish(PressureCheckClassifier.classify(localPressureSamples))
      }
    }
  }

  private func page<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 18) {
      Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.cyan)
      Text(title).font(.largeTitle.bold())
      content()
    }
  }

  private func button(_ title: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action).buttonStyle(.borderedProminent).tint(.cyan)
  }

  private func gesture(_ symbol: String, _ title: String, _ detail: String) -> some View {
    Label {
      VStack(alignment: .leading) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: symbol).frame(width: 28)
    }
  }
}

private struct PressurePad: UIViewRepresentable {
  let onPressure: (Float, CGFloat, CGFloat) -> Void

  func makeUIView(context: Context) -> View {
    let view = View()
    view.onPressure = onPressure
    return view
  }

  func updateUIView(_ uiView: View, context: Context) { uiView.onPressure = onPressure }

  final class View: UIView {
    var onPressure: ((Float, CGFloat, CGFloat) -> Void)?
    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = UIColor.white.withAlphaComponent(0.08)
      layer.cornerRadius = 12
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func report(_ touches: Set<UITouch>) {
      guard let touch = touches.first(where: { $0.type == .pencil }) else { return }
      let maximum = touch.maximumPossibleForce
      let normalized = maximum > 0 ? Float(min(max(touch.force / maximum, 0), 1)) : 0
      onPressure?(normalized, touch.force, maximum)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(touches) }
  }
}
