import Foundation
import Testing

@testable import LifeKit

struct WorkspaceAttachmentsTests {
  @Test @MainActor func demoAndLocalMarkdownCanStageWithoutAHub() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = WorkspaceModel(localURL: { root.appendingPathComponent("workspace.sqlite") })
    await model.open(demo: true)
    let attachments = try #require(model.attachments)
    let outboxRoot = await attachments.store.root
    defer { try? FileManager.default.removeItem(at: outboxRoot) }
    let source = root.appendingPathComponent("synthetic.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("exact fixture".utf8).write(to: source)
    let entry = try await attachments.stage(
      source, name: "synthetic.txt", contentType: "text/plain")
    #expect(entry.state == .queued)
    #expect(model.connection == nil)
    #expect(try await attachments.store.localBytes(for: entry.id) == Data("exact fixture".utf8))
    try await model.client?.close()
  }
}
