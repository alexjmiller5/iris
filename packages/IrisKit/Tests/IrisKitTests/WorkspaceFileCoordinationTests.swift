import Foundation
import Testing

@testable import IrisKit

@Suite(.serialized) @MainActor
struct WorkspaceFileCoordinationTests {
  @Test(arguments: ["same", "symlink"])
  func sameFileWaitsForTheWholeTransactionAndOtherFilesProceed(alias: String) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("workspace.sqlite")
    let runtime = try IrisCoreRuntime()
    let first = try NativeWorkspace(path: path.path, runtime: runtime)
    try await first.createSample()
    let otherPath = folder.appendingPathComponent("alias.sqlite")
    if alias == "symlink" {
      try FileManager.default.createSymbolicLink(at: otherPath, withDestinationURL: path)
    }
    let second = try NativeWorkspace(path: alias == "same" ? path.path : otherPath.path)
    _ = try await second.catalog()
    let independent = try NativeWorkspace(path: folder.appendingPathComponent("other.sqlite").path)
    try await independent.createSample()
    let memory = try NativeWorkspace(path: ":memory:")
    try await memory.createSample()
    runtime.context.evaluateScript(
      #"""
      const original = IrisNative.request;
      let held = false;
      IrisNative.request = function(id, method, args) {
        if (method !== 'catalog') return original(id, method, args);
        IrisSql.begin();
        IrisSql.run("UPDATE notes SET title='Atomic first window'");
        held = true;
        globalThis.releaseWindow = () => {
          IrisSql.commit();
          held = false;
          original(id, method, args);
        };
      };
      """#)
    let holding = Task { try await first.catalog() }
    await wait { runtime.context.evaluateScript("held")?.toBool() == true }
    var saved = false
    let saving = Task {
      defer { saved = true }
      return try await second.write(table: "notes", patch: ["title": .string("Second window save")])
    }
    var read = false
    let reading = Task {
      defer { read = true }
      return try await second.rows(table: "notes")
    }
    var independentFinished = false
    let independentRead = Task {
      defer { independentFinished = true }
      let independentRows = try await independent.rows(table: "notes")
      let memoryRows = try await memory.rows(table: "notes")
      #expect(!independentRows.isEmpty && !memoryRows.isEmpty)
    }
    await wait { independentFinished }
    #expect(!saved && !read, "Neither same-file operation may interleave the held transaction")
    runtime.context.evaluateScript("releaseWindow()")
    _ = try await holding.value
    let receipt = try await saving.value
    let rows = try await reading.value
    #expect(rows.contains { $0.id == receipt["id"]?.text && $0.label == "Second window save" })
    #expect(rows.contains { $0.label == "Atomic first window" })
    try await independentRead.value
    try await second.close()
    // Closing one window must not close the other window's connection.
    #expect(!(try await first.rows(table: "notes")).isEmpty)
    try await first.close()
    try await independent.close()
    try await memory.close()
  }

  @Test func failedOperationReleasesTheFileForAnotherWindowAndClose() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("workspace.sqlite").path
    let runtime = try IrisCoreRuntime()
    let first = try NativeWorkspace(path: path, runtime: runtime)
    try await first.createSample()
    let second = try NativeWorkspace(path: path)
    runtime.context.evaluateScript(
      "IrisNative.request = () => { throw new Error('Synthetic failure'); }")
    await #expect(throws: Error.self) { _ = try await first.catalog() }
    #expect(!(try await second.rows(table: "notes")).isEmpty)
    try await first.close()
    #expect(!(try await second.rows(table: "notes")).isEmpty)
    try await second.close()
  }

  @Test func failedRequestRollsBackBeforeAdmittingAnotherWindow() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("workspace.sqlite").path
    let runtime = try IrisCoreRuntime()
    let first = try NativeWorkspace(path: path, runtime: runtime)
    try await first.createSample()
    let second = try NativeWorkspace(path: path)
    runtime.context.evaluateScript(
      #"""
      IrisNative.request = () => {
        IrisSql.begin();
        IrisSql.run("UPDATE notes SET title='Uncommitted value'");
        throw new Error('Synthetic adapter failure');
      };
      """#)
    await #expect(throws: Error.self) { _ = try await first.catalog() }
    let result = await Task { try await second.rows(table: "notes") }.result
    // Keep even a failing baseline from leaving an intentionally held transaction.
    runtime.context.evaluateScript("try { IrisSql.rollback(); } catch {}")
    try await first.close()
    try await second.close()
    let rows = try result.get()
    #expect(!rows.isEmpty && rows.allSatisfy { $0.label != "Uncommitted value" })
  }

  @Test func hardLinkedDatabaseIsRefusedWithoutChangingItsContents() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("workspace.sqlite")
    let first = try NativeWorkspace(path: path.path)
    try await first.createSample()
    try await first.close()
    let before = try Data(contentsOf: path)
    let alias = folder.appendingPathComponent("alias.sqlite")
    try FileManager.default.linkItem(at: path, to: alias)
    var unexpected: NativeWorkspace?
    #expect(throws: WorkspaceError.self) { unexpected = try NativeWorkspace(path: alias.path) }
    try await unexpected?.close()
    #expect(try Data(contentsOf: path) == before)
  }

  private func wait(_ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(20))
    while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), "The independent operation must reach its completion barrier")
  }
}
