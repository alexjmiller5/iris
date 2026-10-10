import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

/// Opening a record paints from the listed row with no database work, and what
/// streams in afterwards stays cheap: one label read per reference field.
@MainActor
struct RecordOpenPerformanceTests {
  /// `items` has 10 reference columns (5 single, 5 multi with 6 ids each), a 200 KB
  /// Markdown body, and 200 `links` rows reference the opened item.
  private func fixture() async throws -> (NativeWorkspace, IrisCoreRuntime) {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      const system = `id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),
        created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT`;
      const refs = Array.from({length: 10}, (_, i) => `ref${i}`);
      const tables = {
        targets: 'title TEXT',
        items: `title TEXT, body TEXT, ${refs.map(r => r + ' TEXT').join(', ')}`,
        links: 'title TEXT, item_id TEXT',
      };
      for (const [name, columns] of Object.entries(tables)) {
        const ddl = `CREATE TABLE ${name} (${system}, ${columns})`;
        IrisSql.run(ddl);
        IrisSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
        IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES (?,'table','title')", [name]);
        for (const col of ['id','created_at','updated_at','deleted_at','hub_at'])
          IrisSql.run('INSERT INTO catalog_properties(id,tbl,col,type) VALUES (?,?,?,?)', [`${name}.${col}`, name, col, 'text']);
        IrisSql.run('INSERT INTO catalog_properties(id,tbl,col,type) VALUES (?,?,?,?)', [`${name}.title`, name, 'title', 'text']);
      }
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('items.body','items','body','markdown')");
      refs.forEach((r, i) => IrisSql.run('INSERT INTO catalog_properties(id,tbl,col,type,ref_table) VALUES (?,?,?,?,?)',
        [`items.${r}`, 'items', r, i < 5 ? 'ref' : 'multi_ref', 'targets']));
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,type,ref_table) VALUES ('links.item_id','links','item_id','ref','items')");
      const stamp = '2026-01-01T00:00:00.000Z';
      for (let i = 0; i < 40; i++)
        IrisSql.run('INSERT INTO targets(id,created_at,updated_at,title) VALUES (?,?,?,?)', [`t${i}`, stamp, stamp, `Target ${i}`]);
      const values = refs.map((r, i) => i < 5 ? `t${i}` : JSON.stringify(Array.from({length: 6}, (_, j) => `t${(i * 6 + j) % 40}`)));
      IrisSql.run(`INSERT INTO items(id,created_at,updated_at,title,body,${refs.join(',')}) VALUES (?,?,?,?,?,${refs.map(() => '?').join(',')})`,
        ['item', stamp, stamp, 'Opened item', '# Long body\n\n' + 'Paragraph of synthetic text. '.repeat(7000), ...values]);
      for (let i = 0; i < 200; i++)
        IrisSql.run('INSERT INTO links(id,created_at,updated_at,title,item_id) VALUES (?,?,?,?,?)', [`l${i}`, stamp, stamp, `Link ${i}`, 'item']);
      """#)
    try #require(runtime.context.exception == nil)
    return (workspace, runtime)
  }

  @Test func firstPaintPreparesTheListedRowWithinAFrameWithoutDatabaseWork() async throws {
    let (workspace, _) = try await fixture()
    let catalog = try await workspace.catalog()
    let properties = catalog.properties.filter { $0["tbl"] == .string("items") }
    let listed = try #require(try await workspace.rows(table: "items").first)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EditorDraftStore(root: root, workspace: root.appendingPathComponent("db.sqlite"))
    // Other records' recovery journals exist, as on a device that has been used.
    for index in 0..<20 {
      var draft = RecordDraft(properties: properties, original: listed.record)
      draft.values["title"] = "Draft \(index)"
      try store.save(
        StoredEditorDraft(
          table: "items", recordID: "other-\(index)", draft: draft, failure: nil, failedPatch: nil))
    }
    var writes = 0
    let fields = properties.map(CatalogField.init)
    let clock = ContinuousClock()
    var slowest = Duration.zero
    for _ in 0..<10 {
      let elapsed = clock.measure {
        // Everything the editor does before its first frame.
        let editor = RecordEditorModel(
          properties: properties, original: listed.record, table: "items", store: store,
          loaded: false
        ) { _, _ in
          writes += 1
          return [:]
        }
        _ = NativeEditorFields(
          fields: fields, visibleColumns: nil, titleColumn: "title", isNew: false,
          invalidColumns: [],
          emptyColumns: NativeEditorFields.emptyColumns(
            fields: fields, values: listed.record.mapValues(\.text)))
        #expect(editor.draft.values["title"] == "Opened item")
      }
      slowest = max(slowest, elapsed)
    }
    print("first paint preparation, slowest of 10: \(slowest)")
    #expect(slowest < .milliseconds(16), "first paint must fit one frame")
    #expect(writes == 0)
    _ = try await workspace.close()
  }

  @Test func streamedSectionsReadOneLabelRequestPerReferenceField() async throws {
    let (workspace, _) = try await fixture()
    let catalog = try await workspace.catalog()
    let fields = catalog.properties.filter { $0["tbl"] == .string("items") }
      .map(CatalogField.init)
    let row = try #require(try await workspace.rows(table: "items").first?.record)
    var reads = 0
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
      for field in fields where ["ref", "multi_ref"].contains(field.type) {
        let picker = try ReferencePickerModel(
          table: "targets", value: row[field.id]?.text ?? "", multiple: field.type == "multi_ref"
        ) {
          reads += 1
          return try await workspace.rows(view: $0)
        }
        #expect(picker.label(for: picker.selection.ids[0]) == "Loading…")
        await picker.resolveSelected()
        for id in picker.selection.ids { #expect(picker.label(for: id).hasPrefix("Target ")) }
      }
      _ = try await workspace.referenceSources(CoreReferenceSourcesArgs(table: "items"))
      _ = try await workspace.mentionedBy(
        CoreMentionedByArgs(table: "items", rowId: "item", limit: 20))
    }
    print("streamed sections: \(elapsed), \(reads) label reads for 10 reference fields")
    #expect(reads == 10)
    #expect(elapsed < .seconds(2))
    _ = try await workspace.close()
  }
}
