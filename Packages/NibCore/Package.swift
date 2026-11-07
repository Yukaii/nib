// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NibCore",
  platforms: [.macOS(.v14), .iOS(.v18)],
  products: [
    .library(name: "NibCore", targets: ["NibCore"])
  ],
  targets: [
    .target(name: "NibCore"),
    .testTarget(name: "NibCoreTests", dependencies: ["NibCore"]),
  ]
)
