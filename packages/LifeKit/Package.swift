// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LifeKit",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "LifeKit", targets: ["LifeKit"])],
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")],
  targets: [
    .target(
      name: "LifeKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      resources: [
        .copy("Resources/life-core.js"), .copy("Resources/graph.html"),
        .copy("Resources/editor.html"),
      ]),
    .testTarget(name: "LifeKitTests", dependencies: ["LifeKit"], resources: [.copy("Fixtures")]),
  ]
)
