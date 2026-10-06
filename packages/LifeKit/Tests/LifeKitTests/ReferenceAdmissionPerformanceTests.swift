import Foundation
import Testing

@testable import LifeKit

/// Opt-in queue measurements using synthetic catalog/rows and the real native core.
@Suite(.serialized) @MainActor
struct ReferenceAdmissionPerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_REFERENCE_BARRIER"] == "1"))
  func measureNavigationWithQueuedServiceBarrier() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    try seed(runtime)
    runtime.context.evaluateScript(
      #"""
      globalThis.barrierTrace = [];
      globalThis.releaseBarrierOwner = null;
      const request = LifeNative.request;
      let first = true;
      LifeNative.request = function(id, method, args) {
        if (first) {
          first = false;
          LifeSql.begin();
          releaseBarrierOwner = () => { LifeSql.commit(); request(id, method, args); };
          return;
        }
        barrierTrace.push(method);
        if (method === 'serviceNotifications') {
          // Admission-only fixture: never start network or inspect personal state.
          __lifeFinish(id, JSON.stringify({error:'Synthetic service completion'}));
          return;
        }
        return request(id, method, args);
      };
      """#)
    let owner = Task { try await workspace.catalog() }
    defer { runtime.context.evaluateScript("releaseBarrierOwner?.()") }
    try await waitUntil {
      runtime.context.evaluateScript("releaseBarrierOwner !== null")?.toBool() == true
    }
    var queued = 0
    let labels = (0..<300).map { _ in
      Task {
        queued += 1
        return try await workspace.referenceRows(
          view: CoreView(
            table: "notes",
            filters: [
              CoreFilter(
                column: "id", op: .eq,
                value: .string("reference-note-000"))
            ], limit: 1))
      }
    }
    try await waitUntil { queued == labels.count }
    let hub = try HubTransport(endpoint: "https://admission-fixture.invalid", token: "synthetic")
    var serviceQueued = false
    let service = Task {
      serviceQueued = true
      return try await workspace.notifications(using: hub)
    }
    try await waitUntil { serviceQueued }
    let start = ContinuousClock.now
    let navigation = Task {
      try await NativeDestinationResolver(workspace: workspace).resolve(
        NativeDestination(table: "topics"), isCurrent: { true })
    }
    await Task.yield()
    runtime.context.evaluateScript("releaseBarrierOwner(); releaseBarrierOwner = null")
    _ = try await owner.value
    _ = try await navigation.value
    let elapsed = milliseconds(start.duration(to: .now))
    let preceding =
      runtime.context.evaluateScript(
        "barrierTrace.slice(0, barrierTrace.indexOf('catalog')).filter(x => x === 'rows').length"
      )?.toInt32() ?? -1
    print("REFERENCE_BARRIER navigation_ms=\(elapsed) preceding_passive_reads=\(preceding)")
    for label in labels { _ = await label.result }
    _ = await service.result
    try await workspace.close()
    #expect(
      preceding < 300,
      "A queued service must not force navigation through the entire passive backlog")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_REFERENCE_ADMISSION"] == "1"))
  func measureNavigationBehindCancelledReferenceLabels() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    try seed(runtime)
    runtime.context.evaluateScript(
      #"""
      globalThis.referenceTrace = [];
      globalThis.holdReferenceOwner = false;
      globalThis.releaseReferenceOwner = null;
      const referenceRequest = LifeNative.request;
      LifeNative.request = function(id, method, args) {
        if (holdReferenceOwner) {
          holdReferenceOwner = false;
          LifeSql.begin();
          globalThis.releaseReferenceOwner = () => {
            LifeSql.commit();
            releaseReferenceOwner = null;
            referenceRequest(id, method, args);
          };
          return;
        }
        referenceTrace.push({method, milliseconds: Date.now()});
        return referenceRequest(id, method, args);
      };
      """#)
    try #require(runtime.context.exception == nil)
    let baseline = ContinuousClock.now
    let catalog = try await workspace.catalog()
    let catalogMilliseconds = milliseconds(baseline.duration(to: .now))
    #expect(
      catalog.tables.count == 100 && catalog.properties.count == 1000 && catalog.rules.count == 200)
    print(
      "REFERENCE_ADMISSION baseline_catalog_ms=\(catalogMilliseconds) catalog_bytes=\(try JSONEncoder().encode([catalog.tables, catalog.properties, catalog.rules]).count)"
    )

    let model = WorkspaceModel()
    model.client = workspace
    model.catalog = catalog
    for count in [70, 100, 300] {
      for (cancelledCount, cancelOnActivation) in [
        (0, true), (count / 2, true), (count, true), (0, false),
      ] {
        model.table = "notes"
        await model.reload()
        try #require(model.rows.count == 100)
        runtime.context.evaluateScript("referenceTrace = []; holdReferenceOwner = true")
        let blocker = Task { try await workspace.catalog() }
        defer { runtime.context.evaluateScript("releaseReferenceOwner?.()") }
        try await waitUntil {
          runtime.context.evaluateScript("releaseReferenceOwner !== null")?.toBool() == true
        }
        var enqueued = 0
        let labels = (0..<count).map { index in
          Task {
            let field = CatalogField(property: [
              "type": .string("ref"),
              "ref_table": .string(index.isMultiple(of: 2) ? "notes" : "topics"),
            ])
            return await NativePropertyValue.referenceLabels(
              field: field,
              value: index.isMultiple(of: 2) ? "reference-note-000" : "reference-topic"
            ) { view in
              enqueued += 1
              return try await workspace.referenceRows(view: view)
            }
          }
        }
        try await waitUntil { enqueued == count }
        for label in labels.prefix(cancelledCount) { label.cancel() }
        let queuedAt = ContinuousClock.now
        let navigation = Task {
          try await NativeDestinationResolver(workspace: workspace).resolve(
            NativeDestination(table: "topics"), isCurrent: { true })
        }
        // All label calls have entered NativeWorkspace before navigation starts.
        await Task.yield()
        var lastHeartbeat = ContinuousClock.now
        var heartbeatGaps: [Duration] = []
        let heartbeat = Task { @MainActor in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
            let now = ContinuousClock.now
            heartbeatGaps.append(lastHeartbeat.duration(to: now))
            lastHeartbeat = now
          }
        }
        defer { heartbeat.cancel() }
        runtime.context.evaluateScript(
          "globalThis.referenceReleasedAt = Date.now(); releaseReferenceOwner()")
        _ = try await blocker.value
        let resolved = try await navigation.value
        let resolvedMilliseconds = milliseconds(queuedAt.duration(to: .now))
        let context = try model.activateDestination(
          resolved, workspace: workspace, generation: model.workspaceGeneration)
        // Exercise both prompt teardown and delayed SwiftUI task cancellation.
        if cancelOnActivation { labels.forEach { $0.cancel() } }
        await model.reload()
        let visibleMilliseconds = milliseconds(queuedAt.duration(to: .now))
        try #require(!model.loading && model.error == nil && !model.rows.isEmpty)
        #expect(model.table == "topics" && model.writeability?.writable == true)
        let original = try #require(model.rows.first?.record)
        let title = "Synthetic saved navigation \(count)-\(cancelledCount)"
        _ = try await model.save(
          ["id": original["id"]!, "title": .string(title)],
          original: original, context: context)
        #expect(model.rows.contains { $0.record["title"] == .string(title) })
        let savedMilliseconds = milliseconds(queuedAt.duration(to: .now))
        heartbeat.cancel()
        await heartbeat.value
        #expect(resolved.destination == NativeDestination(table: "topics"))
        for (index, label) in labels.enumerated() {
          let value = await label.value
          if cancelOnActivation || index < cancelledCount {
            #expect(value == "Unavailable")
          } else {
            #expect(value.hasPrefix("Synthetic"))
          }
        }
        let counts =
          runtime.context.evaluateScript(
            #"""
            JSON.stringify({
              rows: referenceTrace.filter(entry => entry.method === 'rows').length,
              catalogs: referenceTrace.filter(entry => entry.method === 'catalog').length,
              catalog_admission_ms: referenceTrace.find(entry => entry.method === 'catalog').milliseconds - referenceReleasedAt
            })
            """#)?.toString() ?? "missing"
        try #require(runtime.context.exception == nil)
        print(
          "REFERENCE_ADMISSION labels=\(count) cancelled=\(cancelledCount) cancel_on_activation=\(cancelOnActivation) resolved_ms=\(resolvedMilliseconds) visible_rows_ms=\(visibleMilliseconds) saved_ms=\(savedMilliseconds) max_main_actor_gap_ms=\(milliseconds(heartbeatGaps.max() ?? .zero)) trace=\(counts)"
        )
      }
    }
    try await workspace.close()
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(condition(), "Synthetic queue barrier was not reached")
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }

  /// Generic synthetic catalog with wide records and one larger Markdown body.
  private func seed(_ runtime: LifeCoreRuntime) throws {
    runtime.context.evaluateScript(
      #"""
      LifeSql.begin();
      try {
        LifeSql.run('DELETE FROM notes');
        const types = ['datetime', ...Array(5).fill('json'), ...Array(5).fill('multi_ref'), 'multi_select', 'ref', 'select', 'text', 'text'];
        const description = 'Synthetic catalog metadata. '.repeat(20);
        for (let i = 0; i < types.length; i++) {
          const col = 'reference_field_'+i;
          LifeSql.run('ALTER TABLE notes ADD COLUMN '+col+' TEXT');
          LifeSql.run('INSERT INTO catalog_properties(id,tbl,col,label,type,sort,description,ref_table) VALUES (?,?,?,?,?,?,?,?)',
            ['notes.'+col, 'notes', col, 'Synthetic field '+i, types[i], i+10, description, types[i] === 'ref' ? 'notes' : types[i] === 'multi_ref' ? 'topics' : null]);
        }
        for (const [col, type] of [['id','text'], ['updated_at','datetime']])
          LifeSql.run('INSERT INTO catalog_properties(id,tbl,col,label,type,sort) VALUES (?,?,?,?,?,?)', ['notes.'+col,'notes',col,col,type,100]);
        LifeSql.run("INSERT INTO topics(id,title) VALUES ('reference-topic','Synthetic related record')");
        const tableCount = LifeSql.all('SELECT count(*) AS n FROM catalog_tables')[0].n;
        for (let i = tableCount; i < 100; i++) {
          const table = 'reference_fixture_'+i;
          LifeSql.run('CREATE TABLE '+table+' (id TEXT PRIMARY KEY, updated_at TEXT, deleted_at TEXT, '+Array.from({length:12},(_,n) => 'field_'+n+' TEXT').join(',')+')');
          LifeSql.run('INSERT INTO catalog_tables(id,kind,display,purpose) VALUES (?,?,?,?)', [table,'table','field_0','Synthetic queue scale']);
        }
        const tables = LifeSql.all("SELECT id FROM catalog_tables WHERE id LIKE 'reference_fixture_%' ORDER BY id");
        let properties = LifeSql.all('SELECT count(*) AS n FROM catalog_properties')[0].n;
        for (const {id:table} of tables) {
          for (let i = 0; i < 12 && properties < 1000; i++, properties++)
            LifeSql.run('INSERT INTO catalog_properties(id,tbl,col,label,type,sort,description) VALUES (?,?,?,?,?,?,?)',
              [table+'.field_'+i,table,'field_'+i,'Synthetic field '+i,'text',i,description]);
        }
        for (let i = 0; i < 200; i++)
          LifeSql.run('INSERT INTO catalog_rules(id,tbl,kind,enforce,text) VALUES (?,?,?,?,?)', ['reference-rule-'+i,tables[i%tables.length].id,'guideline',0,description]);
        const json = JSON.stringify({synthetic:'x'.repeat(300)});
        const columns = Array.from({length:16},(_,i) => 'reference_field_'+i).join(',');
        for (let i = 0; i < 500; i++) {
          const id = 'reference-note-'+String(i).padStart(3,'0');
          const body = '# Synthetic heading\n\n'+'x'.repeat((i === 0 ? 180000 : 4000)-21);
          const values = types.map((type,n) => type === 'json' ? json : type === 'multi_ref' ? '[]' : type === 'ref' ? (i%3 ? 'reference-note-000' : null)
            : type === 'multi_select' ? '["alpha","beta"]' : type === 'datetime' ? '2026-01-01T00:00:00Z' : 'Synthetic value '+n);
          LifeSql.run('INSERT INTO notes(id,title,body,status,topic,related,'+columns+') VALUES (?,?,?,?,?,?,'+Array(16).fill('?').join(',')+')',
            [id,'Synthetic note '+i,body,'Draft',i%3 ? 'reference-topic' : null,'[]',...values]);
        }
        LifeSql.commit();
      } catch(error) { LifeSql.rollback(); throw error; }
      """#)
    try #require(runtime.context.exception == nil)
  }
}
