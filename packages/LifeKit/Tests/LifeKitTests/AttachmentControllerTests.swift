import Foundation
import Testing

@testable import LifeKit

struct AttachmentControllerTests {
  @Test func insertionPreservesRawSourceAndEscapesOnlyDisplayName() {
    let entry = StagedAttachment(
      id: "fixture", key: "attachments/fixture", name: "snow [x]\n☃.png", contentType: "image/png",
      bytes: 7, sha256: "hash", state: .queued)
    let raw = "# Exact  heading\r\n\nUntouched **Markdown**  "
    #expect(
      attachmentMarkdown(entry, source: raw) == raw
        + "\n\n![snow \\[x\\] ☃.png](</v1/files/attachments/fixture>)")
  }
  @Test @MainActor func stagedFileBecomesVisibleBeforeAnyNetworkAttempt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("source")
    try Data("fixture".utf8).write(to: file)
    let controller = AttachmentController(
      store: AttachmentStore(root: root.appendingPathComponent("outbox")))
    let entry = try await controller.stage(file, name: "fixture.txt", contentType: "text/plain")
    #expect(controller.entries.count == 1)
    #expect(controller.entries.first?.id == entry.id)
    #expect(controller.entries.first?.state == .queued)
  }
  @Test @MainActor func stoppedWorkspaceCannotStageNewFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("source")
    try Data("fixture".utf8).write(to: file)
    let controller = AttachmentController(
      store: AttachmentStore(root: root.appendingPathComponent("outbox")))
    controller.stop()
    await #expect(throws: CancellationError.self) {
      try await controller.stage(file, name: "fixture.txt", contentType: "text/plain")
    }
    #expect(try await controller.store.entries().isEmpty)
  }
  @Test @MainActor func unreadableOutboxLoadPublishesAnErrorAndKeepsBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let metadata = directory.appendingPathComponent("metadata.json")
    let bytes = directory.appendingPathComponent("bytes")
    try Data("broken metadata".utf8).write(to: metadata)
    try Data("retained bytes".utf8).write(to: bytes)
    let controller = AttachmentController(store: AttachmentStore(root: root))
    await #expect(throws: (any Error).self) { try await controller.refresh() }
    #expect(controller.error != nil)
    #expect(controller.entries.isEmpty)
    #expect(try Data(contentsOf: bytes) == Data("retained bytes".utf8))
  }

}
