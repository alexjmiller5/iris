import Foundation
import Testing

@testable import IrisKit

@MainActor
struct SearchIndexLoopTests {
  private func eventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !(try await condition()) {
      try #require(ContinuousClock.now < deadline, "The search index loop did not catch up")
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test func openingAWorkspaceIndexesItAndScheduledChangesFollow() async throws {
    let model = WorkspaceModel(widgetLibrary: nil)
    await model.open(demo: true)
    let workspace = try #require(model.client)
    let created = try await workspace.write(
      table: "notes", patch: ["title": .string("Wombat loop fixture")])
    model.scheduleSearchIndex()
    try await eventually {
      try await workspace.search(CoreSearchArgs(text: "wombat", table: "notes")).first?.id
        == created["id"]?.text
    }
    // Queued edits go before the remaining backfill; the loop then catches up on its own.
    try await eventually { model.searchIndexing == 0 }
    #expect(try await workspace.searchIndexStep(budgetMs: 0).done)
  }

  @Test func foregroundReadsRunBetweenShortIndexSteps() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<20000) INSERT INTO notes(id,title,updated_at) SELECT printf('bulk-%05d',i),'Bulk note '||i,'2026-01-01T00:00:00.000Z' FROM n");
      """#)
    try #require(runtime.context.exception == nil)
    let model = WorkspaceModel(widgetLibrary: nil)
    model.client = workspace
    model.scheduleSearchIndex()
    // The first step reconciles; wait for one that indexed rows.
    try await eventually { model.searchIndexing > 0 && model.searchIndexing < 20_000 }
    // A search queued now passes the next index step instead of waiting for the whole build.
    let clock = ContinuousClock()
    var hits: [CoreSearchHit] = []
    let elapsed = try await clock.measure {
      hits = try await workspace.search(CoreSearchArgs(text: "bulk", limit: 50))
    }
    #expect(model.searchIndexing > 0, "The index was still catching up")
    #expect(!hits.isEmpty)
    #expect(elapsed < .milliseconds(300), "First search took \(elapsed)")
    try await eventually { model.searchIndexing == 0 }
    #expect(try await workspace.searchIndexStep(budgetMs: 0).done)
    #expect(try await workspace.search(CoreSearchArgs(text: "bulk", limit: 50)).count == 50)
  }

  @Test func aBurstOfForegroundReadsHoldsTheIndexLoopUntilItGoesQuiet() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<5000) INSERT INTO notes(id,title,updated_at) SELECT printf('quiet-%05d',i),'Quiet note '||i,'2026-01-01T00:00:00.000Z' FROM n");
      """#)
    let model = WorkspaceModel(widgetLibrary: nil)
    model.client = workspace
    model.scheduleSearchIndex()
    try await eventually { model.searchIndexing > 0 }  // reconciled: a large catch-up
    let left = model.searchIndexing
    // A table open's reads, back to back: no index step slips in between them.
    for _ in 0..<5 {
      _ = try await workspace.catalog()
      try await Task.sleep(for: .milliseconds(30))
    }
    #expect(model.searchIndexing == left, "No step ran during the burst")
    try await eventually { model.searchIndexing == 0 }
    #expect(try await workspace.searchIndexStep(budgetMs: 0).done)
  }
}
