import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import NibCore
import SwiftUI
import os

private let macLogger = Logger(subsystem: "dev.yukai.nib", category: "mac")

@MainActor
private final class NibMacModel: ObservableObject {
  struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let bounds: CGRect
  }

  @Published var status = "waiting for iPad"
  @Published var displays: [Display] = []
  @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
  @Published var accessibilityTrusted = TabletInjector.isTrusted
  @Published var linkDiagnostics = "link —"

  private var receiver: PenLinkReceiver
  private var injection: PenInjectionWorker
  private var screenObserver: NSObjectProtocol?
  private var accessibilityTimer: Timer?
  private var diagnosticsTimer: Timer?
  private var diagnosticsLogCounter = 0
  private let defaults = UserDefaults.standard
  private let displayKey = "selectedDisplayID"
  private let smoothingKey = "smoothingEnabled"
  @Published var smoothingEnabled = true

  init() {
    let savedSmoothing = UserDefaults.standard.object(forKey: "smoothingEnabled") as? Bool ?? true
    receiver = try! PenLinkReceiver()
    injection = PenInjectionWorker(post: TabletInjector().post, smoothing: savedSmoothing)
    smoothingEnabled = savedSmoothing
    let saved = defaults.object(forKey: displayKey) as? NSNumber
    selectedDisplayID = CGDirectDisplayID(saved?.uint32Value ?? CGMainDisplayID())

    receiver.accept = { [weak self] hello in
      guard let self else { return false }
      return await self.accept(hello)
    }
    let worker = injection
    receiver.onSample = { sample, arrivalNs in
      worker.enqueue(sample, arrivalNs: arrivalNs)
    }
    receiver.onSession = { [weak self] event in
      self?.session(event)
    }
    refreshDisplays()
    receiver.start()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshDisplays() }
    }
    accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let trusted = self.injection.refreshTrust()
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

  var accessibilityLabel: String {
    accessibilityTrusted ? "Accessibility: granted" : "Accessibility: required"
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
    receiver.stop()
    accessibilityTimer?.invalidate()
    diagnosticsTimer?.invalidate()
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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
    receiver.displayWidth = display.bounds.width
    receiver.displayHeight = display.bounds.height
  }

  private func accept(_ hello: ControlMessage.Hello) async -> Bool {
    let rememberKey = "acceptedDevice.\(hello.deviceName)"
    if defaults.bool(forKey: rememberKey) { return true }
    // A menu-bar-only app is never frontmost; without this the prompt can
    // open behind the user's drawing app.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Allow \u{201c}\(hello.deviceName)\u{201d} to control your pointer?"
    alert.informativeText = "Nib will receive Apple Pencil input from this iPad."
    alert.addButton(withTitle: "Allow")
    alert.addButton(withTitle: "Deny")
    let remember = NSButton(checkboxWithTitle: "Remember", target: nil, action: nil)
    alert.accessoryView = remember
    let allowed = alert.runModal() == .alertFirstButtonReturn
    if allowed, remember.state == .on { defaults.set(true, forKey: rememberKey) }
    if !allowed { status = "rejected \(hello.deviceName)" }
    return allowed
  }

  private func session(_ event: PenLinkSessionEvent) {
    switch event {
    case .connected(let hello):
      macLogger.info("session connected: \(hello.deviceName, privacy: .public)")
      injection.surfaceChanged(CGSize(width: hello.surfaceWidth, height: hello.surfaceHeight))
      status =
        receiver.transportIsUSB
        ? "connected via USB to \(hello.deviceName)"
        : "connected via Wi-Fi to \(hello.deviceName)"
    case .geometryChanged(let geometry):
      injection.surfaceChanged(CGSize(width: geometry.surfaceWidth, height: geometry.surfaceHeight))
    case .disconnected:
      macLogger.info("session disconnected")
      injection.sessionEnded()
      status = "waiting for iPad"
    }
  }

  private func refreshDiagnostics() {
    guard receiverStateConnected else {
      linkDiagnostics = "link —"
      return
    }
    let stats = receiver.linkStatsSnapshot()
    let rtt = receiver.latestRTTMs.map { String(format: "%.0f ms", $0) } ?? "—"
    let inject = injection.snapshot()
    linkDiagnostics = String(
      format:
        "%.0f Hz · loss %.1f%% · gap p95 %.0f ms · jitter p95 %.0f ms · delay %.0f ms · post p95 %.1f ms · RTT %@",
      stats.sampleRateHz, stats.lossPercent, stats.interArrivalP95Ms, stats.delayVariationP95Ms,
      inject.playoutDelayMs, inject.injectP95Ms, rtt)
    diagnosticsLogCounter += 1
    if diagnosticsLogCounter >= 5 {
      diagnosticsLogCounter = 0
      macLogger.info("\(self.linkDiagnostics, privacy: .public)")
    }
  }

  private var receiverStateConnected: Bool {
    if case .connected = receiverState { return true }
    return false
  }

  private var receiverState: PenLinkState {
    // The receiver has no public state; a session is reflected by the menu status.
    (status.hasPrefix("connected via USB") || status.hasPrefix("connected via Wi-Fi"))
      ? .connected(status) : .searching
  }
}

@main
struct NibMacApp: App {
  @StateObject private var model = NibMacModel()

  var body: some Scene {
    MenuBarExtra("Nib", systemImage: "pencil.tip") {
      Text("Nib — \(model.status)")
      Text(model.linkDiagnostics)
      Divider()
      if model.accessibilityTrusted {
        Text(model.accessibilityLabel)
      } else {
        Button(model.accessibilityLabel) { model.requestAccessibility() }
      }
      Toggle(
        "Smoothing",
        isOn: Binding(
          get: { model.smoothingEnabled },
          set: { enabled in
            model.setSmoothing(enabled)
          }))
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
      Divider()
      Button("Quit") {
        model.stop()
        NSApplication.shared.terminate(nil)
      }
    }
  }
}
