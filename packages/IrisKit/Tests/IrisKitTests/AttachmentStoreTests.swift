import Foundation
import Testing

@testable import IrisKit

struct AttachmentStoreTests {
  @Test func stagingKeepsExactBytesAfterSourceRemovalAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("source")
    let bytes = Data([0, 255, 10, 13, 226, 152, 131])
    try bytes.write(to: original)
    let outbox = root.appendingPathComponent("outbox")
    let store = AttachmentStore(root: outbox)
    let staged = try await store.stage(
      source: original, name: "Synthetic snow ☃.bin", contentType: "application/octet-stream")
    try FileManager.default.removeItem(at: original)

    let reopened = AttachmentStore(root: outbox)
    let recovered = try await reopened.entries()
    #expect(recovered.count == 1)
    #expect(recovered.first?.key == staged.key)
    #expect(recovered.first?.name == "Synthetic snow ☃.bin")
    #expect(recovered.first?.state == .queued)
    #expect(try await reopened.localBytes(for: staged.id) == bytes)
    #expect(staged.bytes == 7)
    #expect(staged.reference.hasPrefix("/v1/files/"))
  }

  @Test func failedUploadSurvivesRestartAndRetryUsesTheSameImmutableKey() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("source")
    try Data("synthetic attachment".utf8).write(to: original)
    let store = AttachmentStore(root: root.appendingPathComponent("outbox"))
    let entry = try await store.stage(
      source: original, name: "fixture.txt", contentType: "text/plain")
    try await store.uploadPending { _, _ in throw URLError(.notConnectedToInternet) }
    let reopened = AttachmentStore(root: root.appendingPathComponent("outbox"))
    #expect(try await reopened.entries().first?.state == .failed)
    #expect(try await reopened.localBytes(for: entry.id) == Data("synthetic attachment".utf8))
    try await reopened.uploadPending { supplied, file in
      #expect(supplied.key == entry.key)
      let uploadedBytes = try Data(contentsOf: file)
      #expect(uploadedBytes == Data("synthetic attachment".utf8))
      return AttachmentReceipt(
        key: supplied.key, mime: supplied.contentType, bytes: supplied.bytes,
        sha256: supplied.sha256)
    }
    #expect(try await reopened.entries().first?.state == .uploaded)
  }

  @Test func incorrectReceiptCannotDiscardTheOnlyRetainedBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("source")
    try Data("keep these bytes".utf8).write(to: original)
    let store = AttachmentStore(root: root.appendingPathComponent("outbox"))
    let entry = try await store.stage(
      source: original, name: "fixture.txt", contentType: "text/plain")
    try await store.uploadPending { supplied, _ in
      AttachmentReceipt(
        key: supplied.key, mime: supplied.contentType, bytes: supplied.bytes,
        sha256: String(repeating: "0", count: 64))
    }
    #expect(try await store.entries().first?.state == .failed)
    #expect(try await store.localBytes(for: entry.id) == Data("keep these bytes".utf8))
  }

  @Test func overLimitStagingDoesNotPublishAnIncompleteAttachment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("source")
    try Data([1, 2, 3, 4]).write(to: original)
    let store = AttachmentStore(root: root.appendingPathComponent("outbox"), maximumBytes: 3)
    await #expect(throws: (any Error).self) {
      try await store.stage(
        source: original, name: "fixture.bin", contentType: "application/octet-stream")
    }
    #expect(try await store.entries().isEmpty)
  }
  @Test func damagedOutboxIsReportedInsteadOfSilentlySkippingUploads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not JSON".utf8).write(to: directory.appendingPathComponent("metadata.json"))
    let store = AttachmentStore(root: root)
    await #expect(throws: (any Error).self) {
      try await store.uploadPending { entry, _ in
        AttachmentReceipt(
          key: entry.key, mime: entry.contentType, bytes: entry.bytes, sha256: entry.sha256)
      }
    }
  }
  @Test func interruptedUploadRetriesDirectlyAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try Data("restart fixture".utf8).write(to: source)
    let outbox = root.appendingPathComponent("outbox")
    let store = AttachmentStore(root: outbox)
    var entry = try await store.stage(
      source: source, name: "fixture.txt", contentType: "text/plain")
    entry.state = .uploading
    try JSONEncoder().encode(entry).write(
      to: outbox.appendingPathComponent(entry.id).appendingPathComponent("metadata.json"))
    let reopened = AttachmentStore(root: outbox)
    try await reopened.uploadPending { supplied, _ in
      AttachmentReceipt(
        key: supplied.key, mime: supplied.contentType, bytes: supplied.bytes,
        sha256: supplied.sha256)
    }
    #expect(try await reopened.entries().first?.state == .uploaded)
  }
}
