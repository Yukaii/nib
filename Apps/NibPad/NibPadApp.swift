import NibCore
import SwiftUI
import UIKit

@MainActor
final class NetworkSink: PenSampleSink, GestureSink {
  private let sender = PenLinkSender()
  private let settings: PadSettingsStore
  private let usb = UsbLinkListener()
  private let deviceID: String
  private(set) var linkState = "searching"
  private(set) var frontApp = ControlMessage.FrontApp(appID: "", name: "Default")
  private(set) var hostInfo: ControlMessage.HostInfo?
  var onHostsChanged: (([String]) -> Void)?
  var onLinkStateChanged: ((String) -> Void)?
  var onPressureSample: ((Float) -> Void)?
  var onPressureResult: ((PressureCheckResult) -> Void)?
  private var pressureSamples: [Float] = []
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
      let value =
        switch state {
        case .searching: "searching"
        case .connecting: "connecting"
        case .connected(let name): "connected " + name
        case .rejected(let reason): "rejected: " + reason
        }
      self?.linkState = value
      self?.onLinkStateChanged?(value)
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
      let state = connected ? "connected via USB" : "searching"
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
    if sample.kind == .down || sample.kind == .move || sample.kind == .up {
      onPressureSample?(sample.pressure)
      pressureSamples.append(sample.pressure)
      if pressureSamples.count > 64 { pressureSamples.removeFirst() }
      pressureResult = PressureCheckClassifier.classify(pressureSamples)
      onPressureResult?(pressureResult)
    }
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
  @State private var linkState = "searching"
  @State private var pressureSamples: [Float] = []
  @State private var pressureResult: PressureCheckResult = .notEnoughData
  private let sink: NetworkSink

  init() {
    let settings = PadSettingsStore()
    _settings = State(initialValue: settings)
    sink = NetworkSink(settings: settings)
    sink.onHostsChanged = { hosts in NotificationCenter.default.post(name: .nibHostsChanged, object: hosts) }
    sink.onLinkStateChanged = { state in
      NotificationCenter.default.post(name: .nibLinkStateChanged, object: state)
    }
    sink.onPressureSample = { value in
      NotificationCenter.default.post(name: .nibPressureSample, object: value)
    }
    sink.onPressureResult = { result in
      NotificationCenter.default.post(name: .nibPressureResult, object: result)
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
            pressureSamples: pressureSamples,
            chooseMac: { sink.chooseMac($0) },
            finish: { result in
              pressureResult = result
              UserDefaults.standard.set(true, forKey: "nib.onboardingCompleted")
              onboardingCompleted = true
            })
        } else if linkState != "connected via USB" && !linkState.hasPrefix("connected ") && !panelOpen {
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
        linkState = note.object as? String ?? "searching"
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibPressureSample)) { note in
        if let value = note.object as? Float {
          pressureSamples.append(value)
          if pressureSamples.count > 64 { pressureSamples.removeFirst(pressureSamples.count - 64) }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibPressureResult)) { note in
        pressureResult = note.object as? PressureCheckResult ?? .notEnoughData
      }
    }
  }
}

extension Notification.Name {
  static let nibHostsChanged = Notification.Name("Nib.hostsChanged")
  static let nibLinkStateChanged = Notification.Name("Nib.linkStateChanged")
  static let nibPressureSample = Notification.Name("Nib.pressureSample")
  static let nibPressureResult = Notification.Name("Nib.pressureResult")
}
