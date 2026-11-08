import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import CoreImage
import NibCore
import ServiceManagement
import SwiftUI
import os

private let macLogger = Logger(subsystem: "dev.yukai.nib", category: "mac")

private struct MacPairingPanelView: View {
  let peerName: String
  let code: String
  let pair: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Pair with \(peerName)?").font(.title2.bold())
      Text("Make sure your iPad shows \(code).")
      HStack {
        Button("Pair", action: pair).keyboardShortcut(.defaultAction)
        Button("Cancel", action: cancel)
      }
    }
    .padding(24)
    .frame(width: 360)
  }
}

@MainActor
private final class PairingPanelController: NSWindowController {
  private let pair: () -> Void
  private let cancel: () -> Void

  init(peerName: String, code: String, pair: @escaping () -> Void, cancel: @escaping () -> Void) {
    self.pair = pair
    self.cancel = cancel
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
      // Not closable: closing without Pair/Cancel would leave pairing pending
      // until its timeout.
      styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    update(peerName: peerName, code: code)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(peerName: String, code: String) {
    window?.contentView = NSHostingView(
      rootView: MacPairingPanelView(peerName: peerName, code: code, pair: pair, cancel: cancel))
  }

  func present() {
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

@MainActor
private final class NibMacModel: ObservableObject {
  struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let bounds: CGRect
  }

  @Published var status = "Waiting for iPad…"
  @Published private(set) var connected = false
  @Published private(set) var ipadName: String?
  @Published private(set) var receiverError: String?
  @Published private(set) var pairingMessage: String?
  @Published private(set) var pairedIPads: [String: String] = [:]
  @Published private(set) var launchAtLoginError: String?
  @Published var setupCompleted: Bool {
    didSet { defaults.set(setupCompleted, forKey: setupCompletedKey) }
  }
  @Published private(set) var needsRestart = false
  @Published var showsDiagnostics: Bool {
    didSet { defaults.set(showsDiagnostics, forKey: diagnosticsKey) }
  }
  @Published var displays: [Display] = []
  @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
  @Published var accessibilityTrusted = TabletInjector.isTrusted
  /// Two short lines so the menu stays narrow; empty while disconnected.
  @Published var linkDiagnostics: [String] = []

  private var receiver: PenLinkReceiver?
  private var injection: PenInjectionWorker
  private var screenObserver: NSObjectProtocol?
  private var frontAppObserver: NSObjectProtocol?
  private var accessibilityTimer: Timer?
  private var diagnosticsTimer: Timer?
  private var diagnosticsLogCounter = 0
  private let defaults = UserDefaults.standard
  private let diagnosticsKey = "showsDiagnostics"
  private let displayKey = "selectedDisplayID"
  private let smoothingKey = "smoothingEnabled"
  private let setupCompletedKey = "setupCompleted"
  private let hostID: String
  private let pairingStore: KeychainPairingKeyStore
  private let trustedAtLaunch: Bool
  private var pairingPanel: PairingPanelController?
  private var activePairingPeerName: String?
  @Published var smoothingEnabled = true

  var onboardingStep: MacOnboardingStep {
    MacOnboardingStep.resolve(
      trusted: accessibilityTrusted,
      needsRestart: needsRestart,
      connected: connected,
      setupCompleted: setupCompleted)
  }

  var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

  init() {
    pairingStore = KeychainPairingKeyStore()
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: "nib.hostID") {
      hostID = existing
    } else {
      let generated = UUID().uuidString
      defaults.set(generated, forKey: "nib.hostID")
      hostID = generated
    }
    let oldKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("acceptedDevice.") }
    for key in oldKeys { defaults.removeObject(forKey: key) }
    pairedIPads = defaults.dictionary(forKey: "nib.pairedIPads") as? [String: String] ?? [:]
    showsDiagnostics = UserDefaults.standard.bool(forKey: "showsDiagnostics")
    setupCompleted = UserDefaults.standard.bool(forKey: setupCompletedKey)
    trustedAtLaunch = TabletInjector.isTrusted
    let savedSmoothing = UserDefaults.standard.object(forKey: "smoothingEnabled") as? Bool ?? true
    injection = PenInjectionWorker(post: TabletInjector().post, smoothing: savedSmoothing)
    smoothingEnabled = savedSmoothing
    do {
      receiver = try PenLinkReceiver(pairingStore: pairingStore, hostID: hostID)
    } catch {
      receiver = nil
      receiverError = "Nib could not start its network listener. Try again."
    }
    let saved = defaults.object(forKey: displayKey) as? NSNumber
    selectedDisplayID = CGDirectDisplayID(saved?.uint32Value ?? CGMainDisplayID())

    if let receiver {
      configure(receiver)
    }
    frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier != Bundle.main.bundleIdentifier,
        let bundleID = app.bundleIdentifier,
        let name = app.localizedName
      else { return }
      Task { @MainActor in
        self?.sendFrontApp(appID: bundleID, name: name)
      }
    }
    refreshDisplays()
    receiver?.start()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshDisplays() }
    }
    accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let trusted = self.injection.refreshTrust()
        if trusted && !self.accessibilityTrusted && !self.trustedAtLaunch {
          self.needsRestart = true
        }
        if trusted != self.accessibilityTrusted {
          macLogger.info("Accessibility state changed: \(trusted ? "granted" : "required", privacy: .public)")
        }
        self.accessibilityTrusted = trusted
      }
    }
    diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshDiagnostics() }
    }
  }

  private func configure(_ receiver: PenLinkReceiver) {
    receiver.hostInfo = .init(
      platform: .macos,
      name: Host.current().localizedName ?? "Mac",
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      capabilities: [
        ControlMessage.Capability.tilt, ControlMessage.Capability.hover,
        ControlMessage.Capability.eraser, ControlMessage.Capability.keys,
        ControlMessage.Capability.scroll, ControlMessage.Capability.zoomModifierScroll,
        ControlMessage.Capability.zoomNative, ControlMessage.Capability.rotateNative,
        ControlMessage.Capability.undoRedo, ControlMessage.Capability.frontApp,
      ])
    receiver.accept = { [weak self] hello in
      guard let self else { return false }
      return await self.accept(hello)
    }
    let worker = injection
    receiver.onSample = { sample, arrivalNs in worker.enqueue(sample, arrivalNs: arrivalNs) }
    receiver.onGesture = { gesture in worker.enqueue(gesture) }
    receiver.onSession = { [weak self] event in self?.session(event) }
    receiver.onPairingEvent = { [weak self] event in self?.pairing(event) }
  }

  func retryReceiver() {
    receiver?.stop()
    do {
      let receiver = try PenLinkReceiver(pairingStore: pairingStore, hostID: hostID)
      configure(receiver)
      self.receiver = receiver
      receiverError = nil
      status = "Waiting for iPad…"
      receiver.start()
    } catch {
      receiverError = "Nib could not start its network listener. Try again."
      status = receiverError ?? "Nib could not start its network listener."
    }
  }

  func restartNib() {
    stop()
    let pid = ProcessInfo.processInfo.processIdentifier
    let bundlePath = shellQuote(Bundle.main.bundleURL.path)
    let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open --new \(bundlePath)"
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
    relaunch.arguments = ["/bin/sh", "-c", script]
    relaunch.standardInput = FileHandle.nullDevice
    relaunch.standardOutput = FileHandle.nullDevice
    relaunch.standardError = FileHandle.nullDevice
    do {
      try relaunch.run()
    } catch {
      macLogger.error("Could not schedule Nib restart: \(error.localizedDescription, privacy: .public)")
    }
    NSApplication.shared.terminate(nil)
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      launchAtLoginError = nil
      objectWillChange.send()
    } catch {
      launchAtLoginError = "Nib could not change the launch-at-login setting. Try again."
    }
  }

  func chooseDisplay(_ display: Display) {
    selectedDisplayID = display.id
    defaults.set(display.id, forKey: displayKey)
    configureDisplay(display)
  }

  func setSmoothing(_ enabled: Bool) {
    smoothingEnabled = enabled
    defaults.set(enabled, forKey: smoothingKey)
    injection.setSmoothing(enabled)
  }

  func requestAccessibility() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  func stop() {
    receiver?.stop()
    accessibilityTimer?.invalidate()
    diagnosticsTimer?.invalidate()
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    if let frontAppObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontAppObserver) }
  }

  private func refreshDisplays() {
    displays = NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else {
        return nil
      }
      let id = CGDirectDisplayID(number.uint32Value)
      return Display(id: id, name: screen.localizedName, bounds: CGDisplayBounds(id))
    }
    if !displays.contains(where: { $0.id == selectedDisplayID }) {
      selectedDisplayID =
        displays.first(where: { $0.id == CGMainDisplayID() })?.id ?? displays.first?.id
        ?? CGMainDisplayID()
    }
    if let display = displays.first(where: { $0.id == selectedDisplayID }) {
      configureDisplay(display)
    }
  }

  private func configureDisplay(_ display: Display) {
    macLogger.info("display changed: \(display.name, privacy: .public)")
    injection.displayChanged(display.bounds)
    receiver?.displayWidth = display.bounds.width
    receiver?.displayHeight = display.bounds.height
  }

  private func accept(_ hello: ControlMessage.Hello) async -> Bool { true }

  private func pairing(_ event: PairingTransportEvent) {
    switch event {
    case .pairingRequired(let peerName):
      pairingMessage = "Start pairing on your iPad."
    case .showCode(let code, let peerName):
      activePairingPeerName = peerName
      if let pairingPanel {
        pairingPanel.update(peerName: peerName, code: code)
        pairingPanel.present()
      } else {
        let panel = PairingPanelController(
          peerName: peerName, code: code,
          pair: { [weak self] in self?.receiver?.confirmPairing() },
          cancel: { [weak self] in self?.receiver?.cancelPairing() })
        pairingPanel = panel
        panel.present()
      }
    case .paired(let peerID):
      pairingPanel?.close()
      pairingPanel = nil
      pairedIPads[peerID] = activePairingPeerName ?? pairedIPads[peerID] ?? "iPad"
      activePairingPeerName = nil
      defaults.set(pairedIPads, forKey: "nib.pairedIPads")
      pairingMessage = nil
    case .cancelled:
      pairingPanel?.close()
      pairingPanel = nil
      activePairingPeerName = nil
      pairingMessage = "Pairing was cancelled. Start pairing again on your iPad."
    case .timedOut:
      pairingPanel?.close()
      pairingPanel = nil
      activePairingPeerName = nil
      pairingMessage = "Pairing took too long. Start pairing again on your iPad."
    case .failed(let reason):
      pairingPanel?.close()
      pairingPanel = nil
      activePairingPeerName = nil
      pairingMessage = "Pairing could not finish: \(reason)"
    case .notice(let message):
      pairingMessage = message
    }
  }

  func forget(_ peerID: String) {
    pairingStore.removeKey(for: peerID)
    pairedIPads.removeValue(forKey: peerID)
    defaults.set(pairedIPads, forKey: "nib.pairedIPads")
    receiver?.stop()
    receiver?.start()
    status = "Waiting for iPad…"
  }

  private func session(_ event: PenLinkSessionEvent) {
    switch event {
    case .connected(let hello):
      macLogger.info("session connected: \(String(hello.deviceName.prefix(64)), privacy: .private)")
      injection.surfaceChanged(CGSize(width: hello.surfaceWidth, height: hello.surfaceHeight))
      if let app = NSWorkspace.shared.frontmostApplication,
        let bundleID = app.bundleIdentifier,
        let name = app.localizedName
      {
        sendFrontApp(appID: bundleID, name: name)
      }
      connected = true
      ipadName = hello.deviceName
      pairedIPads[hello.deviceID] = hello.deviceName
      defaults.set(pairedIPads, forKey: "nib.pairedIPads")
      status = "\(hello.deviceName) · Connected via \(receiver?.transportIsUSB == true ? "USB" : "Wi-Fi")"
    case .geometryChanged(let geometry):
      injection.surfaceChanged(CGSize(width: geometry.surfaceWidth, height: geometry.surfaceHeight))
    case .disconnected:
      macLogger.info("session disconnected")
      injection.sessionEnded()
      connected = false
      ipadName = nil
      status = receiverError ?? "Waiting for iPad…"
    }
  }

  private func sendFrontApp(appID: String, name: String) {
    guard appID != Bundle.main.bundleIdentifier else { return }
    receiver?.sendControl(.frontApp(.init(appID: appID, name: name)))
  }

  private func refreshDiagnostics() {
    guard connected else {
      linkDiagnostics = []
      return
    }
    guard let receiver else { return }
    let stats = receiver.linkStatsSnapshot()
    let rtt = receiver.latestRTTMs.map { String(format: "%.0f ms", $0) } ?? "—"
    let inject = injection.snapshot()
    linkDiagnostics = [
      String(
        format: "%.0f Hz · loss %.1f%% · RTT %@", stats.sampleRateHz, stats.lossPercent, rtt),
      String(
        format: "jitter %.0f ms · gap %.0f ms · delay %.0f ms · post %.1f ms",
        stats.delayVariationP95Ms, stats.interArrivalP95Ms, inject.playoutDelayMs, inject.injectP95Ms),
    ]
    diagnosticsLogCounter += 1
    if diagnosticsLogCounter >= 5 {
      diagnosticsLogCounter = 0
      macLogger.info("\(self.linkDiagnostics.joined(separator: " · "), privacy: .public)")
    }
  }
}

private let iPadInstallURL = URL(string: "https://github.com/Yukaii/nib#install")!

private struct QRCodeView: View {
  let image: NSImage?

  init() {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(iPadInstallURL.absoluteString.utf8), forKey: "inputMessage")
    if let output = filter.outputImage {
      let context = CIContext()
      let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
      if let data = context.tiffRepresentation(
        of: scaled, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceGray())
      {
        image = NSImage(data: data)
      } else {
        image = nil
      }
    } else {
      image = nil
    }
  }

  var body: some View {
    Group {
      if let image { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() }
    }
    .frame(width: 150, height: 150)
  }
}

private final class PressureCanvasView: NSView {
  var onPressure: ((CGFloat) -> Void)?
  private var points: [(NSPoint, CGFloat)] = []
  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
    NSColor.controlAccentColor.setFill()
    for (point, pressure) in points {
      let diameter = max(2, 2 + pressure * 26)
      NSBezierPath(
        ovalIn: NSRect(
          x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
      ).fill()
    }
  }

  override func tabletPoint(with event: NSEvent) { record(event) }
  override func mouseDragged(with event: NSEvent) { record(event) }
  override func mouseDown(with event: NSEvent) { record(event) }

  private func record(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let pressure = CGFloat(event.pressure)
    points.append((point, pressure))
    onPressure?(pressure)
    needsDisplay = true
  }
}

private struct PressureCanvas: NSViewRepresentable {
  @Binding var pressure: Double
  func makeNSView(context: Context) -> PressureCanvasView {
    let view = PressureCanvasView()
    view.onPressure = { pressure in self.pressure = Double(pressure) }
    return view
  }
  func updateNSView(_ nsView: PressureCanvasView, context: Context) {
    nsView.onPressure = { pressure in self.pressure = Double(pressure) }
  }
}

private struct SetupView: View {
  @ObservedObject var model: NibMacModel
  @State private var pressure = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Set up Nib").font(.largeTitle.bold())
      Text("Nib turns your iPad and Apple Pencil into a pressure-sensitive drawing tablet for your Mac.")
        .fixedSize(horizontal: false, vertical: true)
      switch model.onboardingStep {
      case .accessibility:
        Text("Nib needs Accessibility permission to send Pencil input to Mac apps.")
        Button("Grant Accessibility Access…") { model.requestAccessibility() }
      case .restart:
        Text("Accessibility is ready. Nib needs to restart to finish setup.")
        Button("Restart Nib") { model.restartNib() }
      case .connect:
        GroupBox("Get Nib on your iPad") {
          HStack {
            QRCodeView()
            VStack(alignment: .leading, spacing: 8) {
              Text(
                "Get Nib for iPad, then open it on the same Wi-Fi network, or plug it in with USB-C."
              )
              Text(iPadInstallURL.absoluteString).font(.caption).textSelection(.enabled)
            }
          }
        }
        Text(model.receiverError ?? "Open Nib on your iPad on the same Wi-Fi, or plug in with USB-C.")
        if let ipadName = model.ipadName { Text("Connected to \(ipadName)") }
        if model.receiverError != nil { Button("Retry") { model.retryReceiver() } }
      case .tryIt:
        Text("Draw in the canvas with Apple Pencil. The dot grows as you press harder.")
        PressureCanvas(pressure: $pressure).frame(minHeight: 220).clipShape(
          RoundedRectangle(cornerRadius: 10))
        Text(String(format: "Pressure %.2f", pressure)).monospacedDigit()
        Toggle(
          "Launch Nib at login",
          isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
        if let error = model.launchAtLoginError { Text(error).foregroundStyle(.secondary) }
        Button("Looks good") { model.setupCompleted = true }
      case .completed:
        Text("Nib is ready. You can reopen this setup window from the menu any time.")
      }
      Spacer()
    }
    .padding(28)
    .frame(width: 560, height: 470)
    .onAppear { NSApp.activate(ignoringOtherApps: true) }
  }
}

private final class NibMacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // macOS 14 has no defaultLaunchBehavior API, so SwiftUI opens the setup
    // Window at launch; close it when setup is done. Only that window: the
    // status item lives in NSApp.windows too, and closing it hides the icon.
    guard UserDefaults.standard.bool(forKey: "setupCompleted") else { return }
    DispatchQueue.main.async {
      for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("setup") == true {
        window.close()
      }
    }
  }
}

@main
struct NibMacApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: NibMacAppDelegate
  @StateObject private var model = NibMacModel()
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    MenuBarExtra("Nib", systemImage: "pencil.tip") {
      Text(model.status)
      if let pairingMessage = model.pairingMessage {
        Text(pairingMessage).foregroundStyle(.secondary)
      }
      if !model.accessibilityTrusted {
        Button("Grant Accessibility Access…") { model.requestAccessibility() }
      }
      if let error = model.receiverError {
        Text(error).foregroundStyle(.secondary)
        Button("Retry") { model.retryReceiver() }
      }
      if let error = model.launchAtLoginError { Text(error).foregroundStyle(.secondary) }
      if model.showsDiagnostics && !model.linkDiagnostics.isEmpty {
        ForEach(model.linkDiagnostics, id: \.self) { Text($0).font(.caption) }
      }
      Divider()
      Button("Setup…") { openWindow(id: "setup") }
      Toggle(
        "Launch Nib at login",
        isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
      Menu("Display") {
        ForEach(model.displays) { display in
          Button {
            model.chooseDisplay(display)
          } label: {
            HStack {
              Text(display.name)
              if display.id == model.selectedDisplayID { Image(systemName: "checkmark") }
            }
          }
        }
      }
      Menu("Paired iPads") {
        if model.pairedIPads.isEmpty {
          Text("No iPads paired yet")
        } else {
          ForEach(model.pairedIPads.keys.sorted(), id: \.self) { peerID in
            Button("Forget \(model.pairedIPads[peerID] ?? "iPad")") {
              model.forget(peerID)
            }
          }
        }
      }
      Toggle("Smoothing", isOn: Binding(get: { model.smoothingEnabled }, set: { model.setSmoothing($0) }))
      Toggle("Show Diagnostics", isOn: $model.showsDiagnostics)
      Divider()
      Button("Quit Nib") {
        model.stop()
        NSApplication.shared.terminate(nil)
      }.keyboardShortcut("q")
    }
    setupScene
  }

  @SceneBuilder
  private var setupScene: some Scene {
    // SceneBuilder cannot conditionally construct a Scene with the macOS 15
    // defaultLaunchBehavior API. The launch delegate provides the macOS 14
    // fallback by closing the completed-setup window on the first run loop.
    Window("Set up Nib", id: "setup") { SetupView(model: model) }
      .defaultSize(width: 560, height: 470)
      .windowResizability(.contentSize)
  }
}
