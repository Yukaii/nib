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

private func displayUUID(_ id: CGDirectDisplayID) -> String {
  guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
    return "follow-main"
  }
  return (CFUUIDCreateString(nil, uuid) as String?) ?? "follow-main"
}

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
    let uuid: String
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
  @Published var mappingSettings = MappingSettings() {
    didSet { saveMappingSettings() }
  }
  @Published private(set) var mappingFallback = false
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
  private let mappingKey = "mappingSettings"
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

  var mappingBaseRect: CGRect? {
    let descriptors = displays.map { MappingSettings.Display(uuid: $0.uuid, bounds: $0.bounds) }
    return mappingSettings.resolveBaseRect(
      displays: descriptors, mainUUID: displayUUID(CGMainDisplayID()))?.rect
  }

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
    if let data = defaults.data(forKey: mappingKey),
      let saved = try? JSONDecoder().decode(MappingSettings.self, from: data)
    {
      mappingSettings = saved
    } else if let old = defaults.object(forKey: "selectedDisplayID") as? NSNumber {
      mappingSettings = MappingSettings(
        target: .display(uuid: displayUUID(CGDirectDisplayID(old.uint32Value))))
    } else {
      mappingSettings = MappingSettings(target: .followMain)
    }
    saveMappingSettings()

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

  func chooseDisplay(_ display: Display?) {
    mappingSettings.target = display.map { .display(uuid: $0.uuid) } ?? .allDisplays
    applyMapping()
  }

  func setProportions(_ proportions: MappingSettings.Proportions) {
    mappingSettings.proportions = proportions
    applyMapping()
  }

  func setArea(_ area: MappingSettings.Area) {
    mappingSettings.area = area
    applyMapping()
  }

  func setEdgeMargin(_ margin: CGFloat) {
    mappingSettings.edgeMargin = min(0.15, max(0, margin))
    applyMapping()
  }

  private func saveMappingSettings() {
    guard let data = try? JSONEncoder().encode(mappingSettings) else { return }
    defaults.set(data, forKey: mappingKey)
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
      return Display(id: id, uuid: displayUUID(id), name: screen.localizedName, bounds: CGDisplayBounds(id))
    }
    applyMapping()
  }

  private func applyMapping() {
    let descriptors = displays.map { MappingSettings.Display(uuid: $0.uuid, bounds: $0.bounds) }
    guard
      let resolution = mappingSettings.resolve(
        displays: descriptors, mainUUID: displayUUID(CGMainDisplayID()))
    else { return }
    mappingFallback = resolution.usedFallback
    injection.mappingChanged(
      resolution.rect, proportions: mappingSettings.proportions, edgeMargin: mappingSettings.edgeMargin)
    receiver?.displayWidth = resolution.rect.width
    receiver?.displayHeight = resolution.rect.height
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

private struct MappingPreview: View {
  let displays: [NibMacModel.Display]
  let baseRect: CGRect?
  let area: MappingSettings.Area
  let showsActiveArea: Bool
  let setArea: (MappingSettings.Area) -> Void

  var body: some View {
    GeometryReader { proxy in
      let union = displays.dropFirst().reduce(displays.first?.bounds ?? .zero) {
        $0.union($1.bounds)
      }
      let scale = min(proxy.size.width / max(union.width, 1), proxy.size.height / max(union.height, 1))
      let previewBase =
        baseRect.map {
          CGRect(
            x: ($0.minX - union.minX) * scale, y: ($0.minY - union.minY) * scale,
            width: $0.width * scale, height: $0.height * scale)
        } ?? .zero
      let box = MappingSettings.previewRect(for: area, in: previewBase)
      ZStack(alignment: .topLeading) {
        ForEach(displays) { display in
          Rectangle()
            .fill(
              display.bounds == baseRect ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.16)
            )
            .overlay(Text(display.name).font(.caption))
            .frame(width: display.bounds.width * scale, height: display.bounds.height * scale)
            .offset(
              x: (display.bounds.minX - union.minX) * scale, y: (display.bounds.minY - union.minY) * scale)
        }
        if showsActiveArea {
          Rectangle()
            .fill(Color.accentColor.opacity(0.10))
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 3))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
            .contentShape(Rectangle())
            .gesture(
              DragGesture().onChanged { value in
                setArea(
                  MappingSettings.area(
                    from: box.offsetBy(dx: value.translation.width, dy: value.translation.height),
                    in: previewBase))
              })
          Circle()
            .fill(Color.accentColor)
            .frame(width: 20, height: 20)
            .offset(x: box.maxX - 10, y: box.maxY - 10)
            .gesture(
              DragGesture().onChanged { value in
                setArea(
                  MappingSettings.area(
                    from: CGRect(
                      x: box.minX, y: box.minY, width: box.width + value.translation.width,
                      height: box.height + value.translation.height), in: previewBase))
              })
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(8)
    }
    .frame(height: 170)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct EdgeMarginPreview: View {
  let margin: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "rectangle.portrait")
        .font(.title2)
        .overlay {
          GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 2)
              .stroke(Color.accentColor, lineWidth: 2)
              .frame(
                width: proxy.size.width * (1 - 2 * margin),
                height: proxy.size.height * (1 - 2 * margin)
              )
              .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
          }
        }
      Text("The inner area maps to the whole target.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct SettingsView: View {
  @ObservedObject var model: NibMacModel

  private var selectedUUID: String {
    if case .display(let uuid) = model.mappingSettings.target {
      if model.displays.contains(where: { $0.uuid == uuid }) { return uuid }
      return model.displays.first(where: { $0.id == CGMainDisplayID() })?.uuid ?? uuid
    }
    if case .followMain = model.mappingSettings.target {
      return model.displays.first(where: { $0.id == CGMainDisplayID() })?.uuid ?? "all"
    }
    return "all"
  }

  var body: some View {
    Form {
      Section("Drawing area") {
        Picker(
          "Display",
          selection: Binding(
            get: { selectedUUID },
            set: { value in
              if value == "all" {
                model.chooseDisplay(nil)
              } else {
                model.chooseDisplay(model.displays.first { $0.uuid == value })
              }
            })
        ) {
          Text("All displays").tag("all")
          ForEach(model.displays) { display in Text(display.name).tag(display.uuid) }
        }
        if model.mappingFallback {
          Text("The saved display is unavailable. Nib is using the main display until it returns.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Toggle(
          "Whole screen",
          isOn: Binding(
            get: { model.mappingSettings.area == .whole },
            set: { model.setArea($0 ? .whole : .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)) }))
        MappingPreview(
          displays: model.displays,
          baseRect: model.mappingBaseRect,
          area: model.mappingSettings.area,
          showsActiveArea: model.mappingSettings.area != .whole,
          setArea: model.setArea)
        Text("Drag the box to move it; drag the corner to resize.").font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Edge margin")
            Spacer()
            Text("\(Int((model.mappingSettings.edgeMargin * 100).rounded()))%")
              .monospacedDigit()
          }
          Slider(
            value: Binding(
              get: { Double(model.mappingSettings.edgeMargin) },
              set: { model.setEdgeMargin(CGFloat($0)) }), in: 0...0.15, step: 0.01)
          EdgeMarginPreview(margin: model.mappingSettings.edgeMargin)
          Text("Reach the screen's edges (and the Dock) without touching the iPad's edge.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Picker(
          "Pencil proportions",
          selection: Binding(
            get: { model.mappingSettings.proportions },
            set: { model.setProportions($0) })
        ) {
          Text("Keep proportions").tag(MappingSettings.Proportions.keep)
          Text("Stretch to fill").tag(MappingSettings.Proportions.stretch)
        }
      }
      Section("Nib") {
        Toggle("Smoothing", isOn: Binding(get: { model.smoothingEnabled }, set: { model.setSmoothing($0) }))
        Toggle(
          "Launch Nib at login",
          isOn: Binding(
            get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
        if let error = model.launchAtLoginError { Text(error).font(.caption).foregroundStyle(.secondary) }
        Toggle("Show diagnostics", isOn: $model.showsDiagnostics)
      }
      Section("Paired iPads") {
        if model.pairedIPads.isEmpty { Text("No iPads paired yet").foregroundStyle(.secondary) }
        ForEach(model.pairedIPads.keys.sorted(), id: \.self) { peerID in
          HStack {
            Text(model.pairedIPads[peerID] ?? "iPad")
            Spacer()
            Button("Forget") { model.forget(peerID) }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 560)
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
  @Environment(\.openSettings) private var openSettings

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
      Button("Settings…") {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }.keyboardShortcut(",", modifiers: .command)
      Button("Setup…") { openWindow(id: "setup") }
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
    Settings {
      SettingsView(model: model)
    }
  }
}
