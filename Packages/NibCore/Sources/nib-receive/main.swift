import Foundation
import NibCore

@main
struct NibReceive {
  static func main() async {
    do {
      let receiver = try await MainActor.run {
        try PenLinkReceiver { hello in
          print("connected \(hello.deviceName) \(hello.surfaceWidth)x\(hello.surfaceHeight)")
          return true
        }
      }
      await MainActor.run {
        receiver.onSample = { sample in
          print("\(sample.sequence) \(sample.kind) \(sample.x) \(sample.y) \(sample.pressure)")
        }
        receiver.onSession = { event in
          switch event {
          case .connected: print("session connected")
          case .geometryChanged(let geometry):
            print("geometry \(geometry.surfaceWidth)x\(geometry.surfaceHeight)")
          case .disconnected: print("session disconnected")
          }
        }
        receiver.start()
      }
      dispatchMain()
    } catch {
      fputs("nib-receive: \(error)\n", stderr)
      exit(1)
    }
  }
}
