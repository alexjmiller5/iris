import Foundation
import Testing

@testable import LifeKit

@MainActor
struct BulkRecordTests {
  @Test func concurrentRevisionChangeIsRejectedByActualCoreWriter() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"LifeSql.run("INSERT INTO notes (id, title, updated_at) VALUES ('race', 'Before', '2000-01-01T00:00:00.000Z')", [])"#
    )
    runtime.context.evaluateScript(
      #"""
      const bulkRequest = LifeNative.request;
      let raced = false;
      LifeNative.request = function(id, method, json) {
        if (method === 'write' && !raced) {
          raced = true;
          LifeSql.run("UPDATE notes SET title = 'Concurrent change', updated_at = '2026-01-01T00:00:00.000Z' WHERE id = 'race'", []);
        }
        return bulkRequest(id, method, json);
      };
      """#)
    try #require(runtime.context.exception == nil)
    let batch = BulkRecordModel(workspace: workspace, table: "notes", ids: ["race"])
    await batch.start(values: ["title": .string("Must not overwrite")])?.value
    #expect(batch.results.map(\.status) == [.failed])
    let row = try #require(
      try await workspace.rows(view: CoreView(table: "notes")).first { $0.id == "race" })
    #expect(row.record["title"] == .string("Concurrent change"))
    try await workspace.close()
  }

  @Test func actualWriterKeepsPartialSuccessAndExactUnicodeIDs() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let ids = ["é", "missing", "e\u{301}"]
    runtime.context.evaluateScript(
      #"for (const id of ['\u00e9', 'e\u0301']) LifeSql.run('INSERT INTO notes (id, title) VALUES (?, ?)', [id, 'Before'])"#
    )
    runtime.context.evaluateScript(
      #"LifeSql.run("UPDATE catalog_properties SET required = 0 WHERE id = 'notes.title'", [])"#)
    try #require(runtime.context.exception == nil)
    let model = BulkRecordModel(workspace: workspace, table: "notes", ids: ids)
    await model.start(values: ["body": .string("# Exact\r\n\n雪"), "title": .string("")])?.value
    #expect(model.results.map(\.status) == [.succeeded, .failed, .succeeded])
    #expect(model.results.map { Data($0.recordID.utf8) } == ids.map { Data($0.utf8) })
    #expect(model.error == nil && !model.running)
    let rows = try await workspace.rows(view: CoreView(table: "notes"))
    for id in [ids[0], ids[2]] {
      let row = try #require(rows.first { $0.byteExactID == Data(id.utf8) })
      #expect(row.record["body"] == .string("# Exact\r\n\n雪"))
      #expect(row.record["title"] == .string(""))
    }
    try await workspace.close()
  }

  @Test func cancelDuringCommittedWriteKeepsReceiptAndStopsNextRow() async throws {
    let gate = BulkTestGate()
    var writes = 0
    let model = BulkRecordModel(
      ids: ["one", "two"], authorize: {},
      read: { id in
        ["id": .string(id), "updated_at": .string("revision")]
      },
      write: { patch, revision in
        #expect(revision == "revision")
        writes += 1
        await gate.hold()
        return patch
      })
    let work = try #require(model.start(values: ["title": .null]))
    let entered = await gate.waitUntilEntered()
    if !entered { await gate.release() }
    try #require(entered, "The admitted write must reach its held receipt")
    model.cancelRemaining()
    #expect(model.running, "Keep the admitted write owned until its receipt settles")
    #expect(model.start(values: ["title": .string("overlap")]) == nil)
    await gate.release()
    await work.value
    #expect(writes == 1)
    #expect(model.results.map(\.status) == [.succeeded, .unattempted])
    #expect(model.results[0].row?["title"] == .null)
    #expect(!model.running)
  }

  @Test func staleContextAfterReadCannotStartWrite() async {
    var current = true
    var writes = 0
    let model = BulkRecordModel(
      ids: ["one"], authorize: {},
      read: { id in
        current = false
        return ["id": .string(id), "updated_at": .string("revision")]
      },
      write: { patch, _ in
        writes += 1
        return patch
      }, isCurrent: { current })
    await model.start(values: ["title": .string("new")])?.value
    #expect(writes == 0)
    #expect(model.results.map(\.status) == [.unattempted])
  }

  @Test func missingRevisionAndAliasCannotBecomeUnconditionalWrites() async {
    var writes = 0
    let model = BulkRecordModel(
      ids: ["é", "missing-revision"], authorize: {},
      read: { id in
        if id == "missing-revision" { return ["id": .string(id)] }
        return ["id": .string("e\u{301}"), "updated_at": .string("revision")]
      },
      write: { patch, _ in
        writes += 1
        return patch
      })
    await model.start(values: ["deleted_at": .string("2026-01-01T00:00:00.000Z")])?.value
    #expect(writes == 0)
    #expect(model.results.map(\.status) == [.failed, .failed])
  }

  @Test func queuedCancellationAndInvalidSelectionDoNotRead() async {
    var reads = 0
    for ids in [["one"], ["one", "one"]] {
      let model = BulkRecordModel(
        ids: ids, authorize: {},
        read: { _ in
          reads += 1
          return [:]
        }, write: { patch, _ in patch })
      let work = model.start(values: ["title": .string("new")])
      if ids.count == 1 { model.cancelRemaining() }
      await work?.value
      if ids.count == 2 { #expect(model.error != nil) }
    }
    #expect(reads == 0)
  }

  @Test func deniedTableAndManagedPatchNeverStartRowReads() async {
    var reads = 0
    let model = BulkRecordModel(
      ids: ["one"], authorize: { throw CocoaError(.fileWriteNoPermission) },
      read: { _ in
        reads += 1
        return [:]
      }, write: { patch, _ in patch })
    await model.start(values: ["id": .string("replacement")])?.value
    #expect(model.error != nil && !model.running)
    await model.start(values: ["title": .string("new")])?.value
    #expect(model.error != nil && !model.running)
    #expect(reads == 0)
    #expect(model.results.map(\.status) == [.unattempted])
  }
}

private actor BulkTestGate {
  private var entered = false
  private var released = false
  private var waiting: CheckedContinuation<Void, Never>?
  private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  func hold() async {
    entered = true
    events.continuation.yield(())
    if released { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func waitUntilEntered() async -> Bool {
    if entered { return true }
    let continuation = events.continuation
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      continuation.finish()
    }
    defer { watchdog.cancel() }
    var iterator = events.stream.makeAsyncIterator()
    return await iterator.next() != nil
  }
  func release() {
    released = true
    waiting?.resume()
    waiting = nil
  }
}
