import NibCore
import SwiftUI
import UIKit
import os

private let padLogger = Logger(subsystem: "dev.yukai.nib", category: "pad")

@MainActor
final class NetworkSink: PenSampleSink, GestureSink {
  private let sender = PenLinkSender()
  private let settings: PadSettingsStore
  private let usb = UsbLinkListener()
  private let deviceID: String
  private let pairingStore = KeychainPairingKeyStore()
  private let initialHostID: String
  private let defaults = UserDefaults.standard
  private var pairingTransport: USBPairingTransport?
  private(set) var linkState: PenLinkState = .searching
  private(set) var frontApp = ControlMessage.FrontApp(appID: "", name: "Default")
  private(set) var hostInfo: ControlMessage.HostInfo?
  var onHostsChanged: (([String]) -> Void)?
  var onLinkStateChanged: ((PenLinkState) -> Void)?
  var onPairingEvent: ((PairingTransportEvent) -> Void)?
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
    initialHostID = defaults.string(forKey: "nib.hostPeerID") ?? "pending-host"
    sender.stateHandler = { [weak self] state in
      self?.linkState = state
      self?.onLinkStateChanged?(state)
    }
    sender.hostsHandler = { [weak self] hosts in self?.onHostsChanged?(hosts) }
    sender.onFrontApp = { [weak self] app in self?.frontApp = app }
    sender.onHostInfo = { [weak self] info in self?.hostInfo = info }
    sender.onPairingEvent = { [weak self] event in self?.handlePairingEvent(event, transport: .wifi) }
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
    usb.onLiveConnectionChanged = { [weak self] live in
      self?.handleUSBLiveConnectionChanged(live)
    }
    usb.onFrontApp = { [weak self] app in self?.frontApp = app }
    usb.onHostInfo = { [weak self] info in self?.hostInfo = info }
    usb.onPairingEvent = { [weak self] event in self?.handlePairingEvent(event, transport: .usb) }
    sender.configurePairing(store: pairingStore, hostID: initialHostID)
    usb.configurePairing(store: pairingStore, hostID: initialHostID)
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

  func beginPairing() {
    let transport = USBPairingTransport.choose(usbHasLiveConnection: usb.hasLiveConnection)
    pairingTransport = transport
    switch transport {
    case .usb:
      usb.beginPairing(deviceID: deviceID, deviceName: UIDevice.current.name)
    case .wifi:
      sender.beginPairing(deviceID: deviceID, deviceName: UIDevice.current.name)
    }
  }

  func confirmPairing() {
    switch pairingTransport {
    case .usb: usb.confirmPairing()
    case .wifi: sender.confirmPairing()
    case nil: break
    }
  }

  func cancelPairing() {
    switch pairingTransport {
    case .usb: usb.cancelPairing()
    case .wifi: sender.cancelPairing()
    case nil: break
    }
  }

  func pairAgain() {
    pairingTransport = USBPairingTransport.choose(usbHasLiveConnection: usb.hasLiveConnection)
    padLogger.info(
      "pair tapped transport=\(self.pairingTransport == .usb ? "usb" : "wifi", privacy: .public)")
    switch pairingTransport {
    case .usb: usb.pairAgain()
    case .wifi: sender.pairAgain()
    case nil: beginPairing()
    }
  }

  func forgetMac() {
    guard let hostID = defaults.string(forKey: "nib.hostPeerID") else { return }
    pairingStore.removeKey(for: hostID)
    defaults.removeObject(forKey: "nib.hostPeerID")
    pairingTransport = USBPairingTransport.choose(usbHasLiveConnection: usb.hasLiveConnection)
    pairAgain()
  }

  private func handlePairingEvent(_ event: PairingTransportEvent, transport: USBPairingTransport) {
    guard
      PairingTransportRoutingDecision.accepts(
        eventTransport: transport, selectedTransport: pairingTransport)
    else { return }
    if case .paired(let peerID) = event { defaults.set(peerID, forKey: "nib.hostPeerID") }
    onPairingEvent?(event)
  }

  private func handleUSBLiveConnectionChanged(_ live: Bool) {
    let decision = PairingTransportRoutingDecision.transition(
      current: pairingTransport,
      usbLive: live,
      wifiPairingActive: sender.pairingPhase != nil)
    pairingTransport = decision.transport
    if let switchEvent = decision.switchEvent {
      onPairingEvent?(switchEvent)
    }
    sender.setWiFiPausedForUSB(live)
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
  @State private var pairingUI = PairingUIState()
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
    sink.onPairingEvent = { event in
      NotificationCenter.default.post(name: .nibPairingEvent, object: event)
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
            pairingCode: pairingUI.code, pairingPeer: pairingUI.peer,
            chooseMac: { sink.chooseMac($0) },
            pair: {
              switch pairingUI.pairButtonAction {
              case .beginPairing: sink.beginPairing()
              case .confirmPairing: sink.confirmPairing()
              }
            },
            cancelPairing: { sink.cancelPairing() },
            pairAgain: { sink.pairAgain() },
            pairingError: pairingUI.error,
            pairingNotice: pairingUI.notice,
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
            }, forgetMac: { sink.forgetMac() }, pressureResult: pressureResult,
            pairingNotice: pairingUI.notice, showsHUD: $showsHUD
          )
          .padding(20)
          .onReceive(NotificationCenter.default.publisher(for: .closeCompanionPanel)) { _ in
            panelOpen = false
          }
        }
      }
      .sheet(isPresented: $pairingUI.sheetPresented) {
        PairingInstructionsView(
          pairingCode: pairingUI.code, pairingPeer: pairingUI.peer,
          pair: {
            switch pairingUI.pairButtonAction {
            case .beginPairing: sink.beginPairing()
            case .confirmPairing: sink.confirmPairing()
            }
          },
          cancel: {
            sink.cancelPairing()
            pairingUI.dismiss()
          },
          pairAgain: {
            sink.pairAgain()
            pairingUI.startAgain()
          },
          error: pairingUI.error, notice: pairingUI.notice
        )
        .presentationDetents([.medium])
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibHostsChanged)) { note in
        hosts = note.object as? [String] ?? []
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibLinkStateChanged)) { note in
        linkState = note.object as? PenLinkState ?? .searching
      }
      .onReceive(NotificationCenter.default.publisher(for: .nibPairingEvent)) { note in
        guard let event = note.object as? PairingTransportEvent else { return }
        pairingUI.reduce(event, onboardingCompleted: onboardingCompleted)
        switch event {
        case .paired:
          if !onboardingCompleted && onboardingStep == 3 { onboardingStep = 4 }
        case .pairingRequired(let peer):
          linkState = .rejected("Pair with \(peer) to start.")
        default: break
        }
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
  static let nibPairingEvent = Notification.Name("Nib.pairingEvent")
}
