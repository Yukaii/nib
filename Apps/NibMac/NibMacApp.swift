import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import NibCore
import SwiftUI

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

  private var receiver: PenLinkReceiver
  private var injection: PenInjectionController
  private var screenObserver: NSObjectProtocol?
  private var accessibilityTimer: Timer?
  private let defaults = UserDefaults.standard
  private let displayKey = "selectedDisplayID"

  init() {
    receiver = try! PenLinkReceiver()
    injection = PenInjectionController(post: TabletInjector().post)
    let saved = defaults.object(forKey: displayKey) as? NSNumber
    selectedDisplayID = CGDirectDisplayID(saved?.uint32Value ?? CGMainDisplayID())

    receiver.accept = { [weak self] hello in
      guard let self else { return false }
      return await self.accept(hello)
    }
    receiver.onSample = { [weak self] sample in
      _ = self?.injection.handle(sample)
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
      Task { @MainActor in self?.accessibilityTrusted = TabletInjector.isTrusted }
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
    injection.displayChanged(display.bounds)
    receiver.displayWidth = display.bounds.width
    receiver.displayHeight = display.bounds.height
  }

  private func accept(_ hello: ControlMessage.Hello) async -> Bool {
    let rememberKey = "acceptedDevice.\(hello.deviceName)"
    if defaults.bool(forKey: rememberKey) { return true }
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
      injection.surfaceChanged(CGSize(width: hello.surfaceWidth, height: hello.surfaceHeight))
      status = "connected to \(hello.deviceName)"
    case .geometryChanged(let geometry):
      injection.surfaceChanged(CGSize(width: geometry.surfaceWidth, height: geometry.surfaceHeight))
    case .disconnected:
      injection.sessionEnded()
      status = "waiting for iPad"
    }
  }
}

@main
struct NibMacApp: App {
  @State private var model = NibMacModel()

  var body: some Scene {
    MenuBarExtra("Nib", systemImage: "pencil.tip") {
      Text("Nib — \(model.status)")
      Divider()
      if model.accessibilityTrusted {
        Text(model.accessibilityLabel)
      } else {
        Button(model.accessibilityLabel) { model.requestAccessibility() }
      }
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
