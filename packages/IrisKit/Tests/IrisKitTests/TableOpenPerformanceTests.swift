import Foundation
import Testing

@testable import IrisKit

/// Opening a table through the real JSC core, GRDB and WorkspaceModel paths.
/// IRIS_TABLE_OPEN_DB=<a disposable copy of a real database> prints per-stage
/// timings for IRIS_TABLE_OPEN_TABLES (default tasks); the file is modified.
@Suite(.serialized) @MainActor
struct TableOpenPerformanceTests {
  /// 10,000 rows of wide text with five reference columns, beside a large catalog.
  @Test func wideTableOpensWithoutCatalogRereadOrPerCellLabelReads() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      IrisSql.begin();
      IrisSql.run("CREATE TABLE targets (id TEXT PRIMARY KEY, title TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)");
      IrisSql.run("CREATE TABLE wide (id TEXT PRIMARY KEY, title TEXT, body TEXT, a TEXT, b TEXT, c TEXT, d TEXT, e TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)");
      IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('targets','table','title'),('wide','table','title')");
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,label,type,sort) VALUES ('targets.title','targets','title','Title','text',0),('wide.title','wide','title','Title','text',0),('wide.body','wide','body','Body','text',1)");
      for (const [col, type] of [['a','ref'],['b','ref'],['c','ref'],['d','multi_ref'],['e','multi_ref']])
        IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,label,type,sort,ref_table) VALUES (?,?,?,?,?,2,'targets')", ['wide.'+col,'wide',col,col.toUpperCase(),type]);
      // Unrelated catalog bulk: a full catalog read costs what it does on a large estate.
      for (let t = 0; t < 50; t++) {
        IrisSql.run(`CREATE TABLE bulk_${t} (id TEXT PRIMARY KEY, ${Array.from({length: 20}, (_, c) => `field_${c} TEXT`).join(', ')}, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT)`);
        IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES (?,'table','field_0')", [`bulk_${t}`]);
        IrisSql.run("WITH RECURSIVE n(c) AS (SELECT 0 UNION ALL SELECT c+1 FROM n WHERE c<19) INSERT INTO catalog_properties(id,tbl,col,label,type,sort,description) SELECT ?||'.field_'||c,?,'field_'||c,'Field '||c,'text',c,printf('%.400c','x') FROM n", [`bulk_${t}`, `bulk_${t}`]);
      }
      IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300) INSERT INTO targets(id,title,updated_at) SELECT 'target-'||i,'Target '||i,'2026-01-01T00:00:00.000Z' FROM n");
      IrisSql.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<10000) INSERT INTO wide(id,title,body,a,b,c,d,e,updated_at) SELECT printf('wide-%05d',i),'Row '||i,printf('%.2048c','w'),'target-'||(i%300+1),'target-'||((i+1)%300+1),'target-'||((i+2)%300+1),json_array('target-'||((i+3)%300+1),'target-'||((i+4)%300+1)),json_array('target-'||((i+5)%300+1)),'2026-01-01T00:00:00.000Z' FROM n");
      IrisSql.commit();
      """#)
    try #require(runtime.context.exception == nil)
    let model = WorkspaceModel(widgetLibrary: nil)
    model.client = workspace
    model.catalog = try await workspace.catalog()
    model.table = "notes"
    await model.reload()
    runtime.context.evaluateScript(
      #"""
      globalThis.openTrace = [];
      const traced = IrisNative.request;
      IrisNative.request = function(id, method, args) { openTrace.push(method); return traced(id, method, args); };
      """#)
    let clock = ContinuousClock()
    let started = clock.now
    let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
      NativeDestination(table: "wide"), isCurrent: { true })
    _ = try model.activateDestination(
      resolved, workspace: workspace, generation: model.workspaceGeneration)
    let painted = started.duration(to: clock.now)
    var visible: Duration?
    let watcher = Task { @MainActor in
      while !Task.isCancelled, model.rows.first?.record["id"]?.text.hasPrefix("wide-") != true {
        try? await Task.sleep(for: .milliseconds(1))
      }
      if !Task.isCancelled { visible = started.duration(to: clock.now) }
    }
    await model.reload()
    if model.error != nil { watcher.cancel() }
    _ = await watcher.value
    try #require(model.error == nil && model.rows.count == 100)
    let labelsStarted = clock.now
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
    var resolvedLabels: [String] = []
    for cell in cells { resolvedLabels.append(await cell.value) }
    let labels = labelsStarted.duration(to: clock.now)
    let trace = runtime.context.evaluateScript("openTrace")?.toArray() as? [String] ?? []
    print(
      "tableOpenGuard painted_ms=\(milliseconds(painted)) rows_visible_ms=\(milliseconds(visible ?? .zero)) labels_ms=\(milliseconds(labels)) cells=\(cells.count) trace=\(trace)"
    )
    #expect(cells.count == 150 && resolvedLabels.allSatisfy { $0.hasPrefix("Target ") })
    #expect(!trace.contains("catalog"), "An unchanged catalog is not read again")
    #expect(trace.filter { $0 == "rows" }.count == 1, "One page of rows, no per-cell reads")
    #expect(trace.filter { $0 == "mentionLabels" }.count == 1, "Visible cells share one label read")
    #expect(
      (trace.firstIndex(of: "rows") ?? .max) < (trace.firstIndex(of: "writeability") ?? .max),
      "Editing checks wait until rows are loaded")
    // Generous for shared CI runners; local runs are a fraction of these.
    #expect(painted < .milliseconds(500))
    #expect(visible.map { $0 < .seconds(1) } == true)
    #expect(labels < .milliseconds(500))
    try await workspace.close()
  }

  private func milliseconds(_ duration: Duration) -> Int {
    Int(
      Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["IRIS_TABLE_OPEN_DB"] != nil))
  mutating func measureRealDatabase() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: environment["IRIS_TABLE_OPEN_DB"]!)
    let tables = (environment["IRIS_TABLE_OPEN_TABLES"] ?? "tasks").split(separator: ",").map(
      String.init)
    let model = WorkspaceModel(localURL: { url }, widgetLibrary: nil)
    let clock = ContinuousClock()
    let heartbeat = Heartbeat()
    var started = clock.now
    await model.open(url: url)
    try #require(model.error == nil, "\(model.error ?? "")")
    report("open", started)
    let workspace = try #require(model.client)
    // The first record a user opens: its backlinks answer from what the index step has built.
    if let first = try await workspace.rows(view: CoreView(table: tables[0], limit: 1)).first {
      heartbeat.reset()
      started = clock.now
      let page = try await workspace.mentionedBy(
        CoreMentionedByArgs(table: tables[0], rowId: first.id, limit: 20))
      report(
        "first backlinks rows=\(page.rows.count) indexing=\(page.indexing) left=\(model.searchIndexing)",
        started)
    }
    let prefixes = (environment["IRIS_TABLE_OPEN_SEARCH"] ?? "t,ta,tas,task,tasks").split(
      separator: ",")
    for prefix in prefixes {
      started = clock.now
      let hits = try await workspace.search(CoreSearchArgs(text: String(prefix), limit: 50))
      report("search \(prefix) hits=\(hits.count)", started)
    }
    try printRequests(workspace)
    for table in tables {
      heartbeat.reset()
      started = clock.now
      let resolved = try await NativeDestinationResolver(workspace: workspace).resolve(
        NativeDestination(table: table), isCurrent: { true })
      report("\(table) resolve", started)
      let activated = clock.now
      _ = try model.activateDestination(
        resolved, workspace: workspace, generation: model.workspaceGeneration)
      await model.reload()
      try #require(model.error == nil, "\(model.error ?? "")")
      report("\(table) activate+reload rows=\(model.rows.count)", activated)
      report("\(table) first rows (total)", started)
      try printRequests(workspace)
      let labels = clock.now
      let fields = model.properties.map(CatalogField.init(property:)).filter {
        ["ref", "multi_ref"].contains($0.type)
      }
      // The grid mounts its visible cells together; each resolves its own labels.
      let cellTasks = model.rows.prefix(30).flatMap { row in
        fields.compactMap { field -> Task<String, Never>? in
          let value = field.formValue(row.record[field.id])
          guard !value.isEmpty else { return nil }
          return Task {
            await NativePropertyValue.referenceLabels(
              field: field, value: value, workspace: workspace)
          }
        }
      }
      for cell in cellTasks { _ = await cell.value }
      let cells = cellTasks.count
      report("\(table) reference labels cells=\(cells)", labels)
      print("tableOpen \(table) max_main_actor_gap_ms=\(heartbeat.worstMilliseconds)")
    }
    heartbeat.reset()
    started = clock.now
    await model.searchIndexSettled()
    report("search index caught up (after the stages above)", started)
    print("tableOpen index catch-up max_main_actor_gap_ms=\(heartbeat.worstMilliseconds)")
    heartbeat.stop()
    try await workspace.close()
  }

  private var printed: UInt64 = 0
  /// Per-request queue, core, SQL and decode milliseconds since the last call.
  private mutating func printRequests(_ workspace: NativeWorkspace) throws {
    let report = try workspace.diagnosticReport(version: "0", build: "0")
    let snapshot = try #require(
      (try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])?["snapshot"]
        as? [String: Any])
    for record in snapshot["completed"] as? [[String: Any]] ?? [] {
      let id = (record["id"] as? NSNumber)?.uint64Value ?? 0
      guard id > printed else { continue }
      printed = id
      let metrics = record["metrics"] as? [String: Any] ?? [:]
      func ms(_ value: Any?) -> String {
        String(format: "%.1f", (value as? NSNumber)?.doubleValue ?? 0)
      }
      print(
        "tableOpen request=\(record["method"] ?? "") queued_ms=\(ms(record["queuedMilliseconds"])) core_ms=\(ms(record["coreRequestMilliseconds"])) sql_ms=\(ms(metrics["sqlMilliseconds"])) sql_count=\(metrics["sqlCount"] ?? 0) decode_ms=\(ms(metrics["decodeMilliseconds"])) bytes=\(metrics["responseBytes"] ?? 0)"
      )
    }
  }

  private func report(_ stage: String, _ started: ContinuousClock.Instant) {
    let elapsed = started.duration(to: .now)
    let ms =
      Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    print("tableOpen stage=\"\(stage)\" elapsed_ms=\(String(format: "%.1f", ms))")
  }
}

/// Longest main-actor stall observed by a 1 ms ticker.
@MainActor final class Heartbeat {
  private var task: Task<Void, Never>?
  private var last = ContinuousClock.now
  private var worst = Duration.zero
  init() {
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
        guard let self else { return }
        let now = ContinuousClock.now
        self.worst = max(self.worst, self.last.duration(to: now))
        self.last = now
      }
    }
  }
  func reset() {
    last = .now
    worst = .zero
  }
  func stop() { task?.cancel() }
  var worstMilliseconds: Int {
    Int(Double(worst.components.seconds) * 1_000 + Double(worst.components.attoseconds) / 1e15)
  }
}
