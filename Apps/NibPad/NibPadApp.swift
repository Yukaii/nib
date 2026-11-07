import NibCore
import SwiftUI
import UIKit

@MainActor
final class NetworkSink: PenSampleSink, GestureSink {
  private let sender = PenLinkSender()
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
  }

  func send(_ sample: PenSample) { sender.send(sample) }
  func send(_ gesture: NibCore.Gesture) { sender.send(gesture) }
  func updateGeometry(width: Double, height: Double) { sender.updateGeometry(width: width, height: height) }
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
