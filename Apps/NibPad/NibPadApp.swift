import NibCore
import SwiftUI
import UIKit

@MainActor
final class NetworkSink: PenSampleSink, GestureSink {
  private let sender = PenLinkSender()
  private let settings: PadSettingsStore
  private let usb = UsbLinkListener()
  private let deviceID: String
  private(set) var linkState: PenLinkState = .searching
  private(set) var frontApp = ControlMessage.FrontApp(appID: "", name: "Default")
  private(set) var hostInfo: ControlMessage.HostInfo?
  var onHostsChanged: (([String]) -> Void)?
  var onLinkStateChanged: ((PenLinkState) -> Void)?
  private(set) var pressureResult: PressureCheckResult = .notEnoughData
  var selectedHost: String? { sender.selectedHost }

  init(settings: PadSettingsStore) {
    self.settings = settings
    let defaults = UserDefaults.standard
    if let stored = defaults.string(forKey: "nib.deviceID") {
      deviceID = stored
    } else {
      let generated = UUID().uuidString
      defaults.set(generated, forKey: "nib.deviceID")
      deviceID = generated
    }
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    sender.stateHandler = { [weak self] state in
      self?.linkState = state
      self?.onLinkStateChanged?(state)
    }
    sender.hostsHandler = { [weak self] hosts in self?.onHostsChanged?(hosts) }
    sender.onFrontApp = { [weak self] app in self?.frontApp = app }
    sender.onHostInfo = { [weak self] info in self?.hostInfo = info }
    sender.start(
      hello: .init(
        appVersion: appVersion, deviceID: deviceID, deviceName: UIDevice.current.name, surfaceWidth: 0,
        surfaceHeight: 0), rememberedHost: defaults.string(forKey: "nib.selectedMac"))
    let hello = ControlMessage.Hello(
      appVersion: appVersion, deviceID: deviceID, deviceName: UIDevice.current.name, surfaceWidth: 0,
      surfaceHeight: 0)
    usb.stateHandler = { [weak self] connected in
      let state: PenLinkState = connected ? .connected(name: "", viaUSB: true) : .searching
      self?.linkState = state
      self?.onLinkStateChanged?(state)
    }
    usb.onFrontApp = { [weak self] app in self?.frontApp = app }
    usb.onHostInfo = { [weak self] info in self?.hostInfo = info }
    usb.start(hello: hello)
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.usb.resumeListening() }
    }
  }

  func send(_ sample: PenSample) {
    var mapped = sample
    if sample.kind != .hover && sample.kind != .proximityExit {
      mapped.pressure = PressureCurve.apply(sample.pressure, settings.settings.pressure)
    }
    if usb.isConnected { usb.send(mapped) } else { sender.send(mapped) }
  }
  func send(_ gesture: NibCore.Gesture) {
    let message = ControlMessage.gesture(gesture)
    if usb.isConnected { usb.send(message) } else { sender.send(gesture) }
  }
  var padSettings: PadSettings { settings.settings }
  var activeProfile: PadSettings.Profile { settings.settings.profile(forAppID: frontApp.appID) }

  func updateGeometry(width: Double, height: Double) {
    if usb.isConnected {
      usb.send(.geometry(.init(surfaceWidth: width, surfaceHeight: height)))
    } else {
      sender.updateGeometry(width: width, height: height)
    }
  }

  func chooseMac(_ name: String) {
    UserDefaults.standard.set(name, forKey: "nib.selectedMac")
    sender.selectHost(name)
  }
}

@main
struct NibPadApp: App {
  @State private var settings: PadSettingsStore
  @State private var panelOpen = false
  @State private var showsHUD = false
  @State private var onboardingCompleted = UserDefaults.standard.bool(forKey: "nib.onboardingCompleted")
  @State private var onboardingStep = 0
  @State private var hosts: [String] = []
  @State private var linkState: PenLinkState = .searching
  @State private var pressureResult: PressureCheckResult = Self.storedPressureResult
  private let sink: NetworkSink

  init() {
    let settings = PadSettingsStore()
    _settings = State(initialValue: settings)
    sink = NetworkSink(settings: settings)
    sink.onHostsChanged = { hosts in NotificationCenter.default.post(name: .nibHostsChanged, object: hosts) }
    sink.onLinkStateChanged = { state in
      NotificationCenter.default.post(name: .nibLinkStateChanged, object: state)
    }
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        PenCaptureRepresentable(sink: sink, panelOpen: $panelOpen, showsHUD: $showsHUD)
          .ignoresSafeArea()
          .statusBarHidden()
          .persistentSystemOverlays(.hidden)
        if !onboardingCompleted {
          OnboardingView(
            step: $onboardingStep, hosts: hosts, linkState: linkState,
            chooseMac: { sink.chooseMac($0) },
            finish: { result in
              pressureResult = result
              Self.storePressureResult(result)
              UserDefaults.standard.set(true, forKey: "nib.onboardingCompleted")
              onboardingCompleted = true
            })
        } else if !isConnected && !panelOpen {
          ConnectionStatusOverlay(linkState: linkState, selectedHost: sink.selectedHost)
        }
        if panelOpen {
          CompanionPanel(
            store: settings, linkState: linkState, profileName: sink.activeProfile.name,
            frontApp: sink.frontApp, hostInfo: sink.hostInfo,
            showIntroduction: {
              onboardingStep = 0
              onboardingCompleted = false
              panelOpen = false
            },
            changeMac: {
              onboardingStep = 2
              onboardingCompleted = false
              panelOpen = false
            }, pressureResult: pressureResult, showsHUD: $showsHUD
          )
          .padding(20)
          .onReceive(NotificationCenter.default.publisher(for: .closeCompanionPanel)) { _ in
            panelOpen = false
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibHostsChanged)) { note in
        hosts = note.object as? [String] ?? []
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibLinkStateChanged)) { note in
        linkState = note.object as? PenLinkState ?? .searching
      }
    }
  }
}

extension NibPadApp {
  private var isConnected: Bool {
    if case .connected = linkState { return true }
    return false
  }

  private static var storedPressureResult: PressureCheckResult {
    switch UserDefaults.standard.string(forKey: "nib.pressureCheckResult") {
    case "ok": return .ok
    case "noPressure": return .noPressure
    default: return .notEnoughData
    }
  }

  private static func storePressureResult(_ result: PressureCheckResult) {
    let value: String =
      switch result {
      case .ok: "ok"
      case .noPressure: "noPressure"
      case .notEnoughData: "notEnoughData"
      }
    UserDefaults.standard.set(value, forKey: "nib.pressureCheckResult")
  }
}

extension Notification.Name {
  static let nibHostsChanged = Notification.Name("Nib.hostsChanged")
  static let nibLinkStateChanged = Notification.Name("Nib.linkStateChanged")
}
