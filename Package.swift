// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
  // Dart 版と同じく、すべて1つのスレッド（メインアクター）で動かす。
  .defaultIsolation(MainActor.self)
]

let package = Package(
  name: "fm-ee2e-swift",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "fm-ee2e-tui", targets: ["fm-ee2e-tui"])
  ],
  targets: [
    .target(name: "FmEe2eCore", swiftSettings: settings),
    .executableTarget(name: "fm-ee2e-tui", dependencies: ["FmEe2eCore"], swiftSettings: settings),
    .testTarget(name: "FmEe2eCoreTests", dependencies: ["FmEe2eCore"], swiftSettings: settings),
  ],
  swiftLanguageModes: [.v5]
)
