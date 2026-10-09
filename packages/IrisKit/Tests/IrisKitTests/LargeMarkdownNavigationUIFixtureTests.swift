import Foundation
import Testing

@testable import IrisKit

@MainActor
struct LargeMarkdownNavigationUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["IRIS_TEST_MARKDOWN_NAV_SIMULATOR"] != nil))
    func prepareLargeMarkdownNavigationFixture() async throws {
      let env = ProcessInfo.processInfo.environment
      try #require(env["IRIS_TEST_MARKDOWN_NAV_SIMULATOR"] == env["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      try #require(model.client != nil)
      await model.close()
      let local = try WorkspaceModel.localURL()
      let runtime = try IrisCoreRuntime()
      let workspace = try NativeWorkspace(path: local.path, runtime: runtime)
      _ = try await workspace.status()
      runtime.context.setObject(
        env["IRIS_TEST_MARKDOWN_NAV_CATALOG"] == "1",
        forKeyedSubscript: "largeNavigationCatalog" as NSString)
      let seedStart = Date()
      runtime.context.evaluateScript(
        #"""
        const marker = 'Synthetic large Markdown navigation fixture';
        const owner = IrisSql.all("SELECT purpose FROM catalog_tables WHERE id='notes'")[0]?.purpose;
        const existing = IrisSql.all('SELECT title,body FROM notes');
        const pristine = owner === 'A sample collection for local notes.' && existing.length === 1
          && existing[0].title === 'A place to start'
          && existing[0].body === '# A place to start\n\nBrowse, write, and keep the source yours.';
        if (owner !== marker && !pristine)
          throw new Error('Refusing to replace notes not owned by the large Markdown fixture');
        const unit = 'A synthetic paragraph with **bold**, [a link](https://example.invalid), and `code`.\n\n- First item\n- Second item\n\n';
        const sizes = [4096, 65536, 524288];
        const bodies = sizes.map(size => ('# Synthetic heading\n\n' + unit.repeat(Math.ceil(size / unit.length))).slice(0, size));
        IrisSql.begin();
        try {
          IrisSql.run("UPDATE catalog_tables SET kind='table',purpose=? WHERE id='notes'", [marker]);
          IrisSql.run("DELETE FROM notes");
          if (largeNavigationCatalog) {
            const existingColumns = new Set(IrisSql.all("SELECT name FROM pragma_table_info('notes')").map(row => row.name));
            const types = ['datetime', ...Array(5).fill('json'), ...Array(5).fill('multi_ref'), 'multi_select', 'ref', 'select', 'text', 'text'];
            for (let i = 0; i < types.length; i++) {
              const col = 'fixture_'+String(i).padStart(2, '0');
              if (!existingColumns.has(col)) IrisSql.run('ALTER TABLE notes ADD COLUMN '+col+' TEXT');
              IrisSql.run('INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,sort,description,ref_table) VALUES (?,?,?,?,?,?,?,?)',
                ['notes.'+col, 'notes', col, 'Synthetic field '+i, types[i],
                 i+10, 'Synthetic catalog metadata. '.repeat(20), types[i] === 'ref' ? 'notes' : types[i] === 'multi_ref' ? 'topics' : null]);
            }
            for (const [col, type] of [['id','text'], ['updated_at','datetime']])
              IrisSql.run('INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,sort) VALUES (?,?,?,?,?,?)',
                ['notes.'+col, 'notes', col, col, type, 100]);
            for (let i = 0; i < 20; i++)
              IrisSql.run('INSERT OR REPLACE INTO topics(id,title) VALUES (?,?)', ['navigation-topic-'+i, 'Synthetic related record '+i]);
            const tableCount = IrisSql.all('SELECT count(*) AS n FROM catalog_tables')[0].n;
            for (let i = tableCount; i < 85; i++) {
              const table = 'zz_nav_fixture_'+String(i).padStart(3, '0');
              const columns = Array.from({length: 12}, (_, n) => 'field_'+n+' TEXT').join(',');
              const ddl = 'CREATE TABLE '+table+' (id TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT,'+columns+')';
              IrisSql.run(ddl);
              IrisSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
              IrisSql.run('INSERT INTO catalog_tables(id,kind,display,purpose) VALUES (?,?,?,?)',
                [table, 'table', 'field_0', 'Synthetic catalog navigation scale']);
            }
            const tables = IrisSql.all("SELECT id FROM catalog_tables WHERE id LIKE 'zz_nav_fixture_%' ORDER BY id");
            let propertyCount = IrisSql.all('SELECT count(*) AS n FROM catalog_properties')[0].n;
            for (const {id: table} of tables) {
              for (let i = 0; i < 12 && propertyCount < 893; i++) {
                const col = 'field_'+i;
                const id = table+'.'+col;
                if (IrisSql.all('SELECT id FROM catalog_properties WHERE id=?', [id]).length) continue;
                IrisSql.run('INSERT INTO catalog_properties(id,tbl,col,label,type,sort,description) VALUES (?,?,?,?,?,?,?)',
                  [id, table, col, 'Synthetic field '+i, 'text', i, 'Synthetic catalog metadata. '.repeat(20)]);
                propertyCount++;
              }
            }
            for (let i = 0; i < 185; i++) {
              IrisSql.run('INSERT OR REPLACE INTO catalog_rules(id,tbl,kind,enforce,text) VALUES (?,?,?,?,?)',
                ['markdown-nav-rule-'+i, tables[i % tables.length].id, 'guideline', 0, 'Synthetic navigation guidance. '.repeat(20)]);
            }
          }
          for (let i = 0; i < 454; i++) {
            const index = i % 45 === 0 ? 2 : i % 10 === 0 ? 1 : 0;
            const suffix = String(i).padStart(3, '0');
            IrisSql.run("INSERT INTO notes(id,title,body) VALUES (?,?,?)",
              ['markdown-nav-'+suffix, 'Markdown navigation '+suffix, bodies[index]]);
          }
          if (largeNavigationCatalog) {
            const assignments = Array.from({length: 16}, (_, i) => 'fixture_'+String(i).padStart(2, '0')+'=?').join(',');
            for (let row = 0; row < 454; row++) {
              const primary = row % 3 !== 0;
              const values = Array.from({length: 16}, (_, i) => i === 0 ? '2026-01-01T00:00:00Z'
                : i < 6 ? JSON.stringify({synthetic: i, value: 'x'.repeat(row % 97 === 0 && i === 1 ? 3200 : 300)}) : i < 11 ? '[]'
                : i === 11 ? JSON.stringify(['alpha','beta'])
                : i === 12 ? primary && row % 2 === 1 ? 'markdown-nav-000' : null
                : i === 13 ? 'Ready' : i === 14 ? 'Synthetic short text '+('x'.repeat(80)) : 'Synthetic brief record text');
              IrisSql.run("UPDATE notes SET status='Draft',topic=?,related=?,"+assignments+' WHERE id=?',
                [primary && row % 2 === 0 ? 'navigation-topic-0' : null,
                 JSON.stringify(row % 67 === 0 ? ['navigation-topic-1'] : []), ...values,
                 'markdown-nav-'+String(row).padStart(3,'0')]);
            }
          }
          IrisSql.commit();
        } catch (error) { IrisSql.rollback(); throw error; }
        const summary = IrisSql.all('SELECT count(*) AS rows,sum(length(body)) AS bytes,max(length(body)) AS largest FROM notes')[0];
        JSON.stringify(summary);
        """#)
      try #require(runtime.context.exception == nil)
      print(
        "MARKDOWN_NAV seed_seconds=\(Date().timeIntervalSince(seedStart)) rows=454 sizes=4096,65536,524288"
      )
      runtime.context.evaluateScript(
        #"""
        globalThis.markdownNavigationTrace = [];
        const request = IrisNative.request;
        IrisNative.request = function(id, method, json) {
          markdownNavigationTrace.push({stage:'admitted', method, milliseconds:Date.now()});
          return request.call(this, id, method, json);
        };
        const finish = __irisFinish;
        globalThis.__irisFinish = function(id, json) {
          markdownNavigationTrace.push({stage:'js_finished', bytes:json.length, milliseconds:Date.now()});
          finish(id, json);
          markdownNavigationTrace.push({stage:'reply_decoded', milliseconds:Date.now()});
        };
        """#)
      try #require(runtime.context.exception == nil)
      let catalog = try await timed("catalog", runtime: runtime) { try await workspace.catalog() }
      print(
        "MARKDOWN_NAV catalog_tables=\(catalog.tables.count) properties=\(catalog.properties.count) rules=\(catalog.rules.count)"
      )
      if env["IRIS_TEST_MARKDOWN_NAV_CATALOG"] == "1" {
        #expect(catalog.tables.count == 85)
        #expect(catalog.properties.count == 893)
        #expect(catalog.rules.count == 185)
        #expect(catalog.properties.filter { $0["tbl"] == .string("notes") }.count == 23)
      }
      print(
        "MARKDOWN_NAV catalog_bytes=\(try JSONEncoder().encode([catalog.tables, catalog.properties, catalog.rules]).count)"
      )
      _ = try await timed("notes_writeability", runtime: runtime) {
        try await workspace.writeability(table: "notes")
      }
      _ = try await timed("views_writeability", runtime: runtime) {
        try await workspace.writeability(table: "views")
      }
      let rows = try await timed("rows_100", runtime: runtime) {
        try await workspace.rows(view: CoreView(table: "notes", limit: 100))
      }
      #expect(rows.count == 100)
      #expect(rows.allSatisfy { $0.id.hasPrefix("markdown-nav-") })
      print(
        "MARKDOWN_NAV page_body_bytes=\(rows.reduce(0) { $0 + ($1.record["body"]?.text.utf8.count ?? 0) })"
      )
      _ = try await timed("resolve_notes", runtime: runtime) {
        try await NativeDestinationResolver(workspace: workspace).resolve(
          NativeDestination(table: "notes"), isCurrent: { true })
      }
      try await workspace.close()
      if let endpoint = env["IRIS_TEST_MARKDOWN_NAV_HUB"] {
        try #require(URL(string: endpoint)?.host == "127.0.0.1")
        let replica = WorkspaceModel.replicaURL(
          root: local.deletingLastPathComponent(), endpoint: endpoint)
        try FileManager.default.createDirectory(
          at: replica.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: replica.path) {
          try FileManager.default.copyItem(at: local, to: replica)
        }
        try HubCredentialStore().save(
          HubCredentials(endpoint: endpoint, token: "synthetic-markdown-navigation-fixture"))
      }
    }

    private func timed<T>(
      _ name: String, runtime: IrisCoreRuntime, _ operation: () async throws -> T
    ) async rethrows -> T {
      let start = Date()
      defer {
        print(
          "MARKDOWN_NAV \(name)_seconds=\(Date().timeIntervalSince(start)) started_ms=\(start.timeIntervalSince1970 * 1000)"
        )
        let trace =
          runtime.context.evaluateScript("JSON.stringify(markdownNavigationTrace.splice(0))")?
          .toString() ?? "missing"
        print("MARKDOWN_NAV \(name)_trace=\(trace)")
      }
      return try await operation()
    }
  #endif
}
