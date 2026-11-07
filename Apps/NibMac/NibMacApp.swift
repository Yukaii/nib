import NibCore
import SwiftUI

@main
struct NibMacApp: App {
  var body: some Scene {
    MenuBarExtra("Nib", systemImage: "pencil.tip") {
      Text("Nib — waiting for iPad")
      Divider()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }
}
