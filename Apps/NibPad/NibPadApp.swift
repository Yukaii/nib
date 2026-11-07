import NibCore
import SwiftUI

@main
struct NibPadApp: App {
  var body: some Scene {
    WindowGroup {
      Color.black
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
  }
}
