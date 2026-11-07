#if os(macOS)
  import CoreGraphics
  import Foundation
  import NibCore

  guard TabletInjector.isTrusted else {
    fputs(
      "Accessibility permission is required. Grant the terminal app running `swift run` (Terminal, iTerm, etc.) access in System Settings > Privacy & Security > Accessibility.\n",
      stderr)
    exit(1)
  }

  print("Starting pressure-ramp demo in 3 seconds…")
  Thread.sleep(forTimeInterval: 3)

  let start = CGEvent(source: nil)?.location ?? .zero
  var builder = TabletEventBuilder()
  let injector = TabletInjector()
  let sampleCount = 360
  let interval = 1.0 / 240.0
  let startTime = CFAbsoluteTimeGetCurrent()

  for index in 0...sampleCount {
    let t = Double(index) / Double(sampleCount)
    let x = start.x + 400 * t
    let y = start.y + 90 * sin(t * 2 * .pi)
    let pressure = Float(sin(.pi * t))
    let altitude = Float(.pi / 4 + (.pi / 8) * sin(2 * .pi * t))
    let azimuth = Float(2 * .pi * t)
    let kind: PenSample.Kind = index == 0 ? .down : (index == sampleCount ? .up : .move)
    let sample = PenSample(
      kind: kind, sequence: UInt32(index), timestamp: UInt64(t * 1_000_000_000),
      x: Float(t), y: Float(0.5 + 0.25 * sin(t * 2 * .pi)), pressure: pressure, altitude: altitude,
      azimuth: azimuth
    )
    injector.post(sample: sample, at: CGPoint(x: x, y: y), using: &builder)
    let target = startTime + Double(index + 1) * interval
    let remaining = target - CFAbsoluteTimeGetCurrent()
    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
  }

  let exitSample = PenSample(
    kind: .proximityExit, sequence: UInt32(sampleCount + 1), timestamp: 0,
    x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0
  )
  injector.post(sample: exitSample, at: start, using: &builder)
#else
  import Foundation
  print("nib-inject-demo is available on macOS only")
#endif
