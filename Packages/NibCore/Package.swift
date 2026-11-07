// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NibCore",
  platforms: [.macOS(.v14), .iOS(.v18)],
  products: [
    .library(name: "NibCore", targets: ["NibCore"]),
    .executable(name: "nib-inject-demo", targets: ["NibInjectDemo"]),
    .executable(name: "nib-receive", targets: ["nib-receive"]),
    .executable(name: "nib-gesture-demo", targets: ["NibGestureDemo"]),
  ],
  targets: [
    .target(name: "NibCore"),
    .executableTarget(name: "NibInjectDemo", dependencies: ["NibCore"]),
    .executableTarget(name: "nib-receive", dependencies: ["NibCore"]),
    .executableTarget(name: "NibGestureDemo", dependencies: ["NibCore"]),
    .testTarget(name: "NibCoreTests", dependencies: ["NibCore"]),
  ]
)
