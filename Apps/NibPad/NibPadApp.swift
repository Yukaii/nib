import SwiftUI

@main
struct NibPadApp: App {
  @MainActor private let sink = LoggingSink()

  var body: some Scene {
    WindowGroup {
      PenCaptureRepresentable(sink: sink)
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
  }
}
