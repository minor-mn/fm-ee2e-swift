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
    .executable(name: "fm-ee2e", targets: ["fm-ee2e"]),
  ],
  dependencies: [
    // Markdown のプレビュー（V）で、Markdown を読む（GitHub と同じ cmark-gfm）。
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
  ],
  targets: [
    .target(
      name: "FmEe2eCore",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")],
      swiftSettings: settings
    ),
    .executableTarget(name: "fm-ee2e", dependencies: ["FmEe2eCore"], swiftSettings: settings),
    .testTarget(name: "FmEe2eCoreTests", dependencies: ["FmEe2eCore"], swiftSettings: settings),
  ],
  swiftLanguageModes: [.v5]
)
