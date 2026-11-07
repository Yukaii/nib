import NibCore
import SwiftUI
import UIKit

@MainActor
final class NetworkSink: PenSampleSink, GestureSink {
  private let sender = PenLinkSender()
  private let settings: PadSettingsStore
  private let usb = UsbLinkListener()
  private(set) var linkState = "searching"

  init(settings: PadSettingsStore) {
    self.settings = settings
    sender.stateHandler = { [weak self] state in
      self?.linkState =
        switch state {
        case .searching: "searching"
        case .connecting: "connecting"
        case .connected(let name): "connected " + name
        case .rejected(let reason): "rejected: " + reason
        }
    }
    sender.start(
      hello: .init(appVersion: "0.1.0", deviceName: UIDevice.current.name, surfaceWidth: 0, surfaceHeight: 0))
    let hello = ControlMessage.Hello(
      appVersion: "0.1.0", deviceName: UIDevice.current.name, surfaceWidth: 0, surfaceHeight: 0)
    usb.stateHandler = { [weak self] connected in
      self?.linkState = connected ? "connected via USB" : "searching"
    }
    usb.start(hello: hello)
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
  
  func updateGeometry(width: Double, height: Double) {
    if usb.isConnected {
      usb.send(.geometry(.init(surfaceWidth: width, surfaceHeight: height)))
    } else {
      sender.updateGeometry(width: width, height: height)
    }
  }
}

@main
struct NibPadApp: App {
  @State private var settings: PadSettingsStore
  @State private var panelOpen = false
  @State private var showsHUD = false
  private let sink: NetworkSink

  init() {
    let settings = PadSettingsStore()
    _settings = State(initialValue: settings)
    sink = NetworkSink(settings: settings)
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        PenCaptureRepresentable(sink: sink, panelOpen: $panelOpen, showsHUD: $showsHUD)
          .ignoresSafeArea()
          .statusBarHidden()
          .persistentSystemOverlays(.hidden)
        if panelOpen {
          CompanionPanel(store: settings, linkState: sink.linkState, showsHUD: $showsHUD)
            .padding(20)
            .onReceive(NotificationCenter.default.publisher(for: .closeCompanionPanel)) { _ in
              panelOpen = false
            }
        }
      }
    }
  }
}
