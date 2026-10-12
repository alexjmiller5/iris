import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct RejectionInboxTests {
  @Test func missingInboxReadDoesNotInitializeStorage() async throws {
    let runtime = try await IrisCoreRuntime.onCore()
    let workspace = try await NativeWorkspace(path: ":memory:", runtime: runtime)
    let page = try await workspace.rejections()
    #expect(page.rejections.isEmpty && page.nextOffset == nil)
    #expect(
      await runtime.evaluateOnCore(
        #"IrisSql.all("SELECT name FROM main.sqlite_master WHERE name='_core_rejected'", []).length"#
      ) { $0?.toInt32() } == 0)
    try await workspace.close()
  }

  @Test func durableCorePagesReopenAndPreserveRawPayloadsAndExactIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("rejections.sqlite").path
    let runtime = try await IrisCoreRuntime.onCore()
    let workspace = try await NativeWorkspace(path: path, runtime: runtime)
    _ = try await workspace.status()
    await runtime.evaluateOnCore(
      #"""
      for (let i=0;i<205;i++) {
        const id = 'row' + String(i).padStart(3, '0');
        const row = {id, body: 'Fixture body', nullable: null};
        const errors = [{id, message: 'Rejected', future: {nested: [null, 3]}}];
        IrisSql.run('INSERT INTO _core_rejected(tbl,row_id,row,errors) VALUES (?,?,?,?)', ['items',id,JSON.stringify(row),JSON.stringify(errors)]);
      }
      """#)
    #expect(runtime.context.exception == nil)
    try await workspace.close()
    let reopened = try await NativeWorkspace(path: path)
    let model = RejectionInboxModel(
      readStatus: { try await reopened.status() }, readPage: { try await reopened.rejections($0) })
    await model.refresh()
    #expect(model.total == 205 && model.entries.count == 100 && model.nextOffset == 100)
    await model.loadMore()
    #expect(model.entries.count == 200 && model.nextOffset == 200)
    await model.loadMore()
    #expect(model.entries.count == 205 && model.nextOffset == nil)
    #expect(model.entries.first?.submitted["nullable"] == .null)
    #expect(
      model.entries.first?.errors.first?["future"]
        == .object(["nested": .array([.null, .number(3)])]))
    #expect(try await reopened.status().rejected == 205)
    try await reopened.close()

    let exactRuntime = try await IrisCoreRuntime.onCore()
    let exact = try await NativeWorkspace(path: ":memory:", runtime: exactRuntime)
    _ = try await exact.status()
    await exactRuntime.evaluateOnCore(
      #"""
      for (const id of ['\u00e9', 'e\u0301']) {
        IrisSql.run('INSERT INTO _core_rejected(tbl,row_id,row,errors) VALUES (?,?,?,?)', ['items',id,JSON.stringify({id}),JSON.stringify([{id,message:'Rejected'}])]);
      }
      """#)
    #expect(exactRuntime.context.exception == nil)
    let first = try await exact.rejections(CoreRejectionsArgs(limit: 1))
    let second = try await exact.rejections(CoreRejectionsArgs(limit: 1, offset: first.nextOffset))
    #expect(first.nextOffset == 1 && second.nextOffset == nil)
    #expect(
      (first.rejections + second.rejections).map { Data($0.rowID.utf8) } == [
        Data([0x65, 0xcc, 0x81]), Data([0xc3, 0xa9]),
      ])
    #expect(Set((first.rejections + second.rejections).map(\.inboxID)).count == 2)
    try await exact.close()
  }

  @Test func corruptLookaheadRemainsVisibleWithoutChangingStoredData() async throws {
    let runtime = try await IrisCoreRuntime.onCore()
    let workspace = try await NativeWorkspace(path: ":memory:", runtime: runtime)
    _ = try await workspace.status()
    await runtime.evaluateOnCore(
      #"""
      IrisSql.run('INSERT INTO _core_rejected VALUES (?,?,?,?)', ['items','a','{"id":"a"}','[{"id":"a","message":"Rejected"}]']);
      IrisSql.run('INSERT INTO _core_rejected VALUES (?,?,?,?)', ['items','b','{"id":"b"}','private fixture marker']);
      """#)
    #expect(runtime.context.exception == nil)
    do {
      _ = try await workspace.rejections(CoreRejectionsArgs(limit: 1))
      Issue.record("Corrupt lookahead must fail the entire page")
    } catch {
      #expect(error.localizedDescription.contains("Invalid stored rejection data"))
      #expect(!error.localizedDescription.contains("private fixture marker"))
    }
    #expect(try await workspace.status().rejected == 2)
    #expect(
      await runtime.evaluateOnCore(
        #"IrisSql.all("SELECT errors FROM _core_rejected WHERE row_id='b'", [])[0].errors"#
      ) { $0?.toString() } == "private fixture marker")
    do {
      _ = try await workspace.rejections(CoreRejectionsArgs(limit: 201))
      Issue.record("Core page limit must remain enforced")
    } catch { #expect(!error.localizedDescription.isEmpty) }
    try await workspace.close()
  }
}
