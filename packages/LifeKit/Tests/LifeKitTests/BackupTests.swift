import Foundation
import GRDB
import LifeExtensionSupport
import Testing

@testable import LifeKit

struct DumpFileTests {
  static let text = "-- life-data-dump: 1\nhello ünï 😀\n"
  static let gzip = Data(
    base64Encoded: "H4sIAAAAAAAC/9PVVcjJTEvVTUksSdRNKc0tsFIw5MpIzcnJVzi8J+/weoUP82c0cAEAbN4+cCYAAAA=")!

  private func read(_ data: Data) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = try DumpFileReader(url: url)
    var out = ""
    while let chunk = try reader.next() { out += chunk }
    return out
  }

  @Test func gzipAndPlainDumpsReadAsTheSameText() throws {
    #expect(try read(Self.gzip) == Self.text)
    #expect(try read(Data(Self.text.utf8)) == Self.text)
  }

  @Test func damagedOrTruncatedGzipIsRefused() throws {
    var damaged = Self.gzip
    damaged[damaged.count - 6] ^= 0xFF  // CRC-32
    #expect(throws: WorkspaceError.self) { try read(damaged) }
    #expect(throws: WorkspaceError.self) { try read(Self.gzip.prefix(Self.gzip.count - 4)) }
    #expect(throws: WorkspaceError.self) { try read(Self.gzip.prefix(20)) }
  }

  @Test func multibyteCharactersSurviveChunkBoundaries() throws {
    // The reader takes 1 MiB at a time: put a 4-byte character across that edge.
    let text = String(repeating: "a", count: (1 << 20) - 2) + "😀" + "b"
    #expect(try read(Data(text.utf8)) == text)
    #expect(DumpFileReader.completeUTF8Prefix(Data([0x61, 0xF0, 0x9F])) == 1)
    #expect(DumpFileReader.completeUTF8Prefix(Data([0x61, 0xC3, 0xA9])) == 3)
    #expect(throws: WorkspaceError.self) { try read(Data([0x61, 0xFF, 0x62])) }
  }

  @Test func writerPublishesOnlyOnClose() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try DumpFileWriter(url: url)
    try writer.write("partial")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try writer.close()
    #expect(try String(contentsOf: url, encoding: .utf8) == "partial")
    let abandoned = try DumpFileWriter(url: url)
    try abandoned.write("other")
    abandoned.abandon()
    #expect(try String(contentsOf: url, encoding: .utf8) == "partial")
  }
}

@MainActor struct NativeBackupTests {
  private func titles(_ workspace: NativeWorkspace) async throws -> [String] {
    try await workspace.rows(view: CoreView(table: "notes", limit: 100))
      .compactMap { $0.record["title"]?.text }.sorted()
  }

  @Test func exportPreviewRestoreAndUndoThroughTheCore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: root.appendingPathComponent("live.sqlite").path)
    try await workspace.createSample()
    let original = try await titles(workspace)
    let dump = root.appendingPathComponent("dump.sql")
    let exported = try await workspace.exportReplica(to: dump)
    #expect(try String(contentsOf: dump, encoding: .utf8).hasPrefix("-- life-data-dump: 1\n"))
    #expect(!FileManager.default.fileExists(atPath: dump.path + ".partial"))

    _ = try await workspace.write(table: "notes", patch: ["title": .string("Added after the backup")])
    let preview = try await workspace.previewRestore(file: dump)
    #expect(preview.backup == exported)
    let notes = try #require(RestoreRow.rows(preview).first { $0.table == "notes" })
    #expect(notes.change == .replaced)
    #expect(notes.current!.rows == notes.backup!.rows + 1)

    let recovery = root.appendingPathComponent("recovery.sql")
    await #expect(throws: (any Error).self) {
      try await workspace.restoreReplica(file: dump, recovery: recovery, confirm: "Replace")
    }
    #expect(try await titles(workspace).contains("Added after the backup"))
    let result = try await workspace.restoreReplica(file: dump, recovery: recovery, confirm: "replace")
    #expect(result.restored == exported)
    #expect(try await titles(workspace) == original)
    // Undo is a restore of the recovery copy.
    _ = try await workspace.restoreReplica(
      file: recovery, recovery: root.appendingPathComponent("again.sql"), confirm: "replace")
    #expect(try await titles(workspace).contains("Added after the backup"))
    try await workspace.close()
  }

  @Test func aTruncatedBackupLeavesTheReplicaUntouched() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: root.appendingPathComponent("live.sqlite").path)
    try await workspace.createSample()
    let dump = root.appendingPathComponent("dump.sql")
    _ = try await workspace.exportReplica(to: dump)
    let text = try String(contentsOf: dump, encoding: .utf8)
    try text.prefix(text.count - 20).write(to: dump, atomically: true, encoding: .utf8)
    let before = try await titles(workspace)
    await #expect(throws: (any Error).self) {
      try await workspace.restoreReplica(
        file: dump, recovery: root.appendingPathComponent("r.sql"), confirm: "replace")
    }
    #expect(try await titles(workspace) == before)
    try await workspace.close()
  }

  @Test func replicaCopyIsAWholeConsistentDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try NativeWorkspace(path: root.appendingPathComponent("live.sqlite").path)
    try await workspace.createSample()
    let copy = root.appendingPathComponent("copy.sqlite")
    try await workspace.copyReplica(to: copy)
    try await workspace.close()
    let queue = try DatabaseQueue(path: copy.path)
    let (pages, size, notes) = try await queue.read { db in
      (
        try Int.fetchOne(db, sql: "PRAGMA page_count")!, try Int.fetchOne(db, sql: "PRAGMA page_size")!,
        try Int.fetchOne(db, sql: "SELECT count(*) FROM notes")!
      )
    }
    try queue.close()
    let bytes = try #require(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(bytes == pages * size)
    #expect(notes > 0)
  }
}
