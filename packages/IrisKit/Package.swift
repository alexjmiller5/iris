// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "IrisKit",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "IrisKit", targets: ["IrisKit"]), .library(name: "IrisExtensionSupport", targets: ["IrisExtensionSupport"]), .library(name: "IrisWidgetSupport", targets: ["IrisWidgetSupport"])],
  dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")],
  targets: [
    .target(name: "IrisExtensionSupport", linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "IrisWidgetSupport", dependencies: ["IrisExtensionSupport"]),
    .target(
      name: "IrisKit", dependencies: ["IrisExtensionSupport", .product(name: "GRDB", package: "GRDB.swift")],
      resources: [
        .copy("Resources/soma-core.js"), .copy("Resources/graph.html"),
        .copy("Resources/editor.html"),
        .copy("Resources/record-export.js"),
      ]),
    .testTarget(name: "IrisKitTests", dependencies: ["IrisKit", "IrisExtensionSupport", "IrisWidgetSupport"], resources: [.copy("Fixtures")]),
  ]
)
