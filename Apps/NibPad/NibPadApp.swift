import NibCore
import SwiftUI
import UIKit

@MainActor
final class NetworkSink: PenSampleSink {
  private let sender = PenLinkSender()
  private let usb = UsbLinkListener()
  private(set) var linkState = "searching"

  init() {
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
    if usb.isConnected { usb.send(sample) } else { sender.send(sample) }
  }
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
  @MainActor private let sink = NetworkSink()

  var body: some Scene {
    WindowGroup {
      PenCaptureRepresentable(sink: sink)
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
  }
}
