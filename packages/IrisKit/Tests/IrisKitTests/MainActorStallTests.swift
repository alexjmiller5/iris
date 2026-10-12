import Foundation
import Testing

@testable import IrisKit

/// The core (JavaScriptCore and SQLite) runs off the main actor, so the UI never misses a
/// frame while a large request runs: reading a megabyte catalog, opening a 10,000-row table
/// and catching up its search index. A 1 ms main-actor heartbeat records each stage's
/// longest stall.
@Suite(.serialized) @MainActor
struct MainActorStallTests {
  /// One frame at 60 Hz on Apple silicon. The Intel release runner runs debug code about
  /// five times slower, so its allowance scales with it.
  #if arch(x86_64)
    static let frame = 80
  #else
    static let frame = 16
  #endif

  @Test func largeTableOpenAndSearchIndexCatchUpLeaveTheMainActorFree() async throws {
    let runtime = try await IrisCoreRuntime.onCore()
    let workspace = try await NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    await runtime.evaluateOnCore(
      #"""
      IrisSql.begin();
      IrisSql.run("CREATE TABLE targets (id TEXT PRIMARY KEY, title TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)");
      IrisSql.run("CREATE TABLE wide (id TEXT PRIMARY KEY, title TEXT, body TEXT, a TEXT, d TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)");
      IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('targets','table','title'),('wide','table','title')");
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,label,type,sort) VALUES ('targets.title','targets','title','Title','text',0),('wide.title','wide','title','Title','text',0),('wide.body','wide','body','Body','text',1)");
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,label,type,sort,ref_table) VALUES ('wide.a','wide','a','A','ref',2,'targets'),('wide.d','wide','d','D','multi_ref',3,'targets')");
      // Unrelated catalog bulk: about a megabyte, as on a large estate.
      for (let t = 0; t < 120; t++) {
        IrisSql.run(`CREATE TABLE bulk_${t} (id TEXT PRIMARY KEY, ${Array.from({length: 20}, (_, c) => `field_${c} TEXT`).join(', ')}, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)`);
        IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES (?,'table','field_0')", [`bulk_${t}`]);
        IrisSql.run("WITH RECURSIVE n(c) AS (SELECT 0 UNION ALL SELECT c+1 FROM n WHERE c<19) INSERT INTO catalog_properties(id,tbl,col,label,type,sort,description) SELECT ?||'.field_'||c,?,'field_'||c,'Field '||c,'text',c,printf('%.400c','x') FROM n", [`bulk_${t}`, `bulk_${t}`]);
      }
      IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300) INSERT INTO targets(id,title,updated_at) SELECT 'target-'||i,'Target '||i,'2026-01-01T00:00:00.000Z' FROM n");
      IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<10000) INSERT INTO wide(id,title,body,a,d,updated_at) SELECT printf('wide-%05d',i),'Row '||i,printf('Synthetic body %d ',i)||printf('%.2000c','w'),'target-'||(i%300+1),json_array('target-'||((i+3)%300+1),'target-'||((i+4)%300+1)),'2026-01-01T00:00:00.000Z' FROM n");
      IrisSql.commit();
      """#)
    try #require(runtime.context.exception == nil)
    let heartbeat = Heartbeat()
    defer { heartbeat.stop() }
    let model = WorkspaceModel(widgetLibrary: nil)
    model.client = workspace
    // Each stage runs three times; the quietest run counts, so a stray scheduler or another
    // test's JSC timer on the main run loop cannot fail it, while a real stall repeats.
    func quietest(_ stage: () async throws -> Void) async rethrows -> [Int] {
      var gaps: [Int] = []
      for _ in 0..<3 {
        heartbeat.reset()
        try await stage()
        gaps.append(heartbeat.worstMilliseconds)
      }
      return gaps
    }

    let catalog = try await quietest {
      // A changed revision makes each read decode the whole catalog again.
      await runtime.evaluateOnCore(
        "IrisSql.run(\"UPDATE catalog_properties SET description = description || '.' WHERE id = 'bulk_0.field_0'\")"
      )
      heartbeat.reset()
      model.catalog = try await workspace.catalog()
    }
    #expect((model.catalog?.properties.count ?? 0) > 2_400)

    let open = try await quietest {
      model.table = "notes"
      await model.reload()
      heartbeat.reset()
      let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
        NativeDestination(table: "wide"), isCurrent: { true })
      _ = try model.activateDestination(
        resolved, workspace: workspace, generation: model.workspaceGeneration)
      await model.reload()
      try #require(model.error == nil && model.rows.count == 100)
      let fields = model.properties.map(CatalogField.init(property:)).filter {
        ["ref", "multi_ref"].contains($0.type)
      }
      let cells = model.rows.prefix(30).flatMap { row in
        fields.map { field in
          Task {
            await NativePropertyValue.referenceLabels(
              field: field, value: field.formValue(row.record[field.id]), workspace: workspace)
          }
        }
      }
      for cell in cells { #expect(await cell.value.hasPrefix("Target ")) }
    }

    let started = ContinuousClock.now
    var catchUpRuns = 0
    let catchUp = try await quietest {
      if catchUpRuns > 0 {
        // Later runs requeue a fifth of the rows.
        await runtime.evaluateOnCore(
          "IrisSql.run(\"UPDATE wide SET title = title || ' ' WHERE rowid % 5 = 0\")")
      }
      catchUpRuns += 1
      heartbeat.reset()
      model.scheduleSearchIndex()
      await model.searchIndexSettled()
      let caughtUp = try await workspace.searchIndexStep(budgetMs: 0).done
      #expect(caughtUp)
    }
    let catchUpDuration = started.duration(to: .now)
    #expect(
      !(try await workspace.search(CoreSearchArgs(text: "synthetic", table: "wide", limit: 5))
        .isEmpty))
    print(
      "mainActorStall catalog_max_gap_ms=\(catalog) table_open_max_gap_ms=\(open) index_catch_up_max_gap_ms=\(catchUp) index_catch_up=\(catchUpDuration)"
    )
    #expect(
      catalog.min()! < Self.frame, "Reading a large catalog stalled the main actor: \(catalog) ms")
    #expect(
      open.min()! < Self.frame, "Opening a 10,000-row table stalled the main actor: \(open) ms")
    #expect(
      catchUp.min()! < Self.frame, "Search index catch-up stalled the main actor: \(catchUp) ms")
    try await workspace.close()
  }
}
