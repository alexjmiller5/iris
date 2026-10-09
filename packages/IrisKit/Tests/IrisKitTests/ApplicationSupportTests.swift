import Foundation
import Testing

@testable import IrisKit

struct ApplicationSupportTests {
  private func base() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("app-support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func movesThePreRenameDirectoryOnce() throws {
    let base = try base()
    let legacy = base.appendingPathComponent("life-ui", isDirectory: true)
    try FileManager.default.createDirectory(
      at: legacy.appendingPathComponent("replicas"), withIntermediateDirectories: true)
    try Data("local".utf8).write(to: legacy.appendingPathComponent("local.sqlite"))

    let root = try ApplicationSupport.adopt(base: base)
    #expect(root.lastPathComponent == "iris")
    #expect(try Data(contentsOf: root.appendingPathComponent("local.sqlite")) == Data("local".utf8))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("replicas").path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(ApplicationSupport.renamed(root: root))

    ApplicationSupport.acknowledgeRename(root: root)
    #expect(!ApplicationSupport.renamed(root: try ApplicationSupport.adopt(base: base)))
  }

  @Test func anExistingDirectoryWins() throws {
    let base = try base()
    let legacy = base.appendingPathComponent("life-ui", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: base.appendingPathComponent("iris"), withIntermediateDirectories: true)

    let root = try ApplicationSupport.adopt(base: base)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(!ApplicationSupport.renamed(root: root))
  }

  @Test func aFreshInstallCreatesTheDirectory() throws {
    let root = try ApplicationSupport.adopt(base: try base())
    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(!ApplicationSupport.renamed(root: root))
  }
}
