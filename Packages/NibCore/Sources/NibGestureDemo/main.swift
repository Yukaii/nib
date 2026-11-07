import Foundation
import NibCore

#if os(macOS)
  import CoreGraphics

  func usage() {
    print("Usage: nib-gesture-demo [--rotate-only | --zoom-only]")
    print("Posts native magnify and rotate gestures to the frontmost app after a 3 second countdown.")
  }

  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments.contains("--help") || arguments.contains("-h") {
    usage()
    exit(0)
  }
  let rotateOnly = arguments.contains("--rotate-only")
  let zoomOnly = arguments.contains("--zoom-only")
  guard !arguments.contains(where: { $0.hasPrefix("--") && $0 != "--rotate-only" && $0 != "--zoom-only" })
  else {
    usage()
    exit(2)
  }
  guard !(rotateOnly && zoomOnly) else {
    fputs("Choose at most one of --rotate-only and --zoom-only.\n", stderr)
    exit(2)
  }
  guard CGPreflightPostEventAccess() else {
    fputs("Accessibility permission is required for the terminal running swift run.\n", stderr)
    exit(1)
  }

  print("nib-gesture-demo: posting to the frontmost app in 3 seconds…")
  for remaining in stride(from: 3, through: 1, by: -1) {
    print("  \(remaining)…")
    Thread.sleep(forTimeInterval: 1)
  }

  func post(_ events: [CGEvent], label: String) {
    for event in events {
      print(
        "  \(label) type=\(event.type.rawValue) hid=\(event.getIntegerValueField(NativeGestureEventBuilder.Field.hidType)) phase=\(event.getIntegerValueField(NativeGestureEventBuilder.Field.phase))"
      )
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.08)
    }
  }

  var builder = NativeGestureEventBuilder()
  if !rotateOnly {
    post(builder.magnify(delta: 0, phase: .began), label: "magnify began")
    post(builder.magnify(delta: 0.12, phase: .changed), label: "magnify in")
    post(builder.magnify(delta: 0.12, phase: .changed), label: "magnify in")
    post(builder.magnify(delta: 0, phase: .ended), label: "magnify ended")
    post(builder.magnify(delta: 0, phase: .began), label: "magnify began")
    post(builder.magnify(delta: -0.12, phase: .changed), label: "magnify out")
    post(builder.magnify(delta: -0.12, phase: .changed), label: "magnify out")
    post(builder.magnify(delta: 0, phase: .ended), label: "magnify ended")
  }
  if !zoomOnly {
    post(builder.rotate(degrees: 0, phase: .began), label: "rotate began")
    post(builder.rotate(degrees: 15, phase: .changed), label: "rotate +15°")
    post(builder.rotate(degrees: 15, phase: .changed), label: "rotate +15°")
    post(builder.rotate(degrees: 15, phase: .changed), label: "rotate +15°")
    post(builder.rotate(degrees: 0, phase: .ended), label: "rotate ended")
    post(builder.rotate(degrees: 0, phase: .began), label: "rotate began")
    post(builder.rotate(degrees: -15, phase: .changed), label: "rotate -15°")
    post(builder.rotate(degrees: -15, phase: .changed), label: "rotate -15°")
    post(builder.rotate(degrees: -15, phase: .changed), label: "rotate -15°")
    post(builder.rotate(degrees: 0, phase: .ended), label: "rotate ended")
  }
#else
  if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("Usage: nib-gesture-demo [--rotate-only | --zoom-only]")
  } else {
    print("nib-gesture-demo is available on macOS only")
  }
#endif
