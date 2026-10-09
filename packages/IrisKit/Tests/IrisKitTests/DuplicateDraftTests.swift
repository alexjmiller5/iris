import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct DuplicateDraftTests {
  private let fields: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("body"), "type": .string("markdown")],
    ["col": .string("nullable"), "type": .string("text")],
  ]

  private func storeFixture() throws -> (URL, EditorDraftStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (
      root, EditorDraftStore(root: root, workspace: root.appendingPathComponent("fixture.sqlite"))
    )
  }

  @Test func realCoreCopyKeepsPresentRawValuesAndUsesDefaultsOnlyForAbsentColumns() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      #"""
      const ddl = `CREATE TABLE copies (
        id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),
        created_at TEXT, updated_at TEXT, deleted_at TEXT, hub_at TEXT,
        title TEXT, body TEXT, nullable TEXT, qty INTEGER, flag INTEGER,
        code TEXT, tags TEXT, absent TEXT, computed TEXT, retired TEXT, empty_text TEXT, payload TEXT)`;
      IrisSql.run(ddl);
      IrisSql.run('INSERT INTO _schema_log(ddl) VALUES (?)', [ddl]);
      IrisSql.run("INSERT INTO catalog_tables(id,kind,display) VALUES ('copies','table','title')");
      for (const [col,type,defaults,immutable,derived,deprecated] of [
        ['title','text',null,0,null,0], ['body','markdown',null,0,null,0],
        ['nullable','text','Fallback',0,null,0], ['qty','int',null,0,null,0],
        ['flag','bool',null,0,null,0], ['code','text',null,1,null,0],
        ['tags','multi_select',null,0,null,0], ['absent','text','Core default',0,null,0],
        ['computed','text',null,0,'fixture',0], ['retired','text',null,0,null,1],
        ['empty_text','text','Text default',0,null,0], ['payload','json',null,0,null,0],
        ...['id','created_at','updated_at','deleted_at','hub_at'].map(c=>[c,'text',null,0,null,0])
      ]) IrisSql.run('INSERT INTO catalog_properties(id,tbl,col,type,default_value,immutable,derived_by,deprecated) VALUES (?,?,?,?,?,?,?,?)',
        ['copies.'+col,'copies',col,type,defaults,immutable,derived,deprecated]);
      IrisSql.run(`INSERT INTO copies(id,created_at,updated_at,hub_at,title,body,nullable,qty,flag,code,tags,absent,computed,retired)
        VALUES ('source','2000-01-01T00:00:00.000Z','2000-01-02T00:00:00.000Z','2000-01-03T00:00:00.000Z',?,?,NULL,0,0,'SET-ONCE',?,'Not copied','Generated',NULL)`,
        ['Copy',' # Raw\n\ncaf\u00e9 and cafe\u0301\n','[ "Unknown", "e\u0301" ]']);
      """#)
    try #require(runtime.context.exception == nil)
    let jsonSource = " { \"empty\": \"\", \"accent\": \"e\u{301}\" } \n"
    let proof = try await workspace.write(
      table: "copies",
      patch: [
        "id": .string("source"), "empty_text": .string(""), "payload": .string(jsonSource),
      ], expectedUpdatedAt: "2000-01-02T00:00:00.000Z")
    #expect(proof["empty_text"] == .string(""))
    #expect(Data(proof["payload"]!.text.utf8) == Data(jsonSource.utf8))
    runtime.context.evaluateScript(
      "IrisSql.run(\"UPDATE copies SET retired='Retired' WHERE id='source'\")")
    let source = try #require(try await workspace.rows(table: "copies").first?.record)
    var input = source
    input.removeValue(forKey: "absent")
    let properties = try await workspace.catalog().properties.filter {
      $0["tbl"] == .string("copies")
    }
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = runtime.context.evaluateScript("IrisSql.all('SELECT total_changes() AS n')[0].n")!
      .toInt32()
    let editor = RecordEditorModel(
      properties: properties, original: nil, table: "copies", store: store
    ) {
      patch, baseline in
      #expect(baseline == nil)
      return try await workspace.write(table: "copies", patch: patch)
    }
    try editor.installDuplicateDraft(from: input)
    #expect(editor.isNew && editor.draft.original == nil && !editor.autosavePaused)
    #expect(
      editor.draft.patch == [
        "title": .string("Copy"), "body": .string(" # Raw\n\ncafé and cafe\u{301}\n"),
        "nullable": .null, "qty": .string("0.0"), "flag": .bool(false),
        "code": .string("SET-ONCE"), "tags": .string("[ \"Unknown\", \"e\u{301}\" ]"),
        "empty_text": .string(""), "payload": .string(jsonSource),
      ])
    #expect(
      Data(editor.draft.values["body"]!.utf8) == Data(" # Raw\n\ncafé and cafe\u{301}\n".utf8))
    #expect(Data(editor.draft.values["tags"]!.utf8) == Data("[ \"Unknown\", \"e\u{301}\" ]".utf8))
    let savedDraft = try #require(try store.load(table: "copies", recordID: nil))
    #expect(savedDraft.recordID == nil && savedDraft.draft.original == nil)
    #expect(savedDraft.draft.patch["nullable"] == .null)
    #expect(savedDraft.draft.patch["empty_text"] == .string(""))
    #expect(Data(savedDraft.draft.patch["payload"]!.text.utf8) == Data(jsonSource.utf8))
    try await editor.flushMarkdown()
    #expect(
      runtime.context.evaluateScript("IrisSql.all('SELECT total_changes() AS n')[0].n")!.toInt32()
        == before)
    try await editor.saveAll()
    let copy = try #require(editor.draft.original)
    #expect(copy["id"] != source["id"])
    #expect(
      copy["created_at"] != source["created_at"] && copy["updated_at"] != source["updated_at"])
    #expect(copy["deleted_at"] == .null && copy["hub_at"] == .null)
    #expect(copy["nullable"] == .null && copy["absent"] == .string("Core default"))
    #expect(copy["qty"] == .number(0) && copy["flag"] == .number(0))
    #expect(copy["code"] == .string("SET-ONCE"))
    #expect(copy["empty_text"] == .string(""))
    #expect(Data(copy["payload"]!.text.utf8) == Data(jsonSource.utf8))
    #expect(copy["computed"] == .null && copy["retired"] == .null)
    let rows = try await workspace.rows(table: "copies")
    #expect(rows.count == 2 && rows.first { $0.id == "source" }?.record == source)
    #expect(!editor.dirty)
    #expect(try store.all().isEmpty)
    try await workspace.close()
  }

  @Test func copiedEmptyTextSurvivesRecoveryAndNoOpSnapshotsUntilExplicitlyCleared() throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in [:] }
    try editor.installDuplicateDraft(from: ["body": .string(""), "nullable": .null])
    editor.setValue("", for: "body")
    #expect(editor.draft.patch == ["body": .string(""), "nullable": .null])
    let saved = try #require(try store.load(table: "notes", recordID: nil))
    let reopened = RecordEditorModel(
      properties: fields, original: nil, table: "notes", store: store, recovered: saved
    ) { _, _ in [:] }
    reopened.resumeDraft()
    #expect(reopened.draft.patch == ["body": .string(""), "nullable": .null])
    reopened.setValue("", for: "body", explicit: true)
    #expect(reopened.draft.patch == ["body": .null, "nullable": .null])
  }

  @Test func emptyTextReceiptDoesNotEraseAClearMadeWhileSaveWasPending() async throws {
    var pending: CheckedContinuation<WorkspaceRecord, Never>?
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: nil) {
      _, _ in await withCheckedContinuation { pending = $0 }
    }
    try editor.installDuplicateDraft(from: ["body": .string("")])
    let saving = Task { try await editor.saveAll() }
    for _ in 0..<1000 where pending == nil { await Task.yield() }
    let release = try #require(pending)
    editor.setValue("", for: "body", explicit: true)
    release.resume(returning: ["id": .string("created"), "body": .string("")])
    try await saving.value
    #expect(editor.dirty && editor.draft.patch == ["id": .string("created"), "body": .null])
  }

  @Test func emptyTextIntentSurvivesUndoAndLegacyRecoveryRemainsClean() throws {
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: nil) {
      _, _ in [:]
    }
    try editor.installDuplicateDraft(from: ["body": .string("")])
    var draft = editor.draft
    draft.reconcileUndo(["id": .string("created"), "body": .null])
    #expect(draft.patch == ["id": .string("created"), "body": .string("")])
    draft.acknowledge(["id": .string("created"), "body": .string("")], sent: draft.patch)
    #expect(draft.patch == ["id": .string("created")])
    draft.setValue("Typed", for: "body")
    draft.setValue("", for: "body")
    #expect(draft.patch == ["id": .string("created"), "body": .null])
    draft.reconcileUndo(["id": .string("created"), "body": .string("")])
    #expect(draft.patch == ["id": .string("created"), "body": .null])

    var legacy = try JSONDecoder().decode(
      RecordDraft.self,
      from: Data(
        #"""
        {"values":{"body":""},"fields":[{"property":{"col":"body","type":"markdown"}}],
         "initial":{"body":""},"original":{"id":"legacy","body":""}}
        """#.utf8))
    #expect(legacy.patch == ["id": .string("legacy")])
    legacy.setValue("", for: "body")
    #expect(legacy.patch == ["id": .string("legacy"), "body": .null])
  }

  @Test func copyOwnsANewNilRecordJournalAndKeepsEveryOlderRecovery() throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for (id, recordID) in [("old-new-1", nil), ("old-new-2", nil), ("old-source", "source")]
      as [(String, String?)]
    {
      var draft = RecordDraft(properties: fields, original: recordID.map { ["id": .string($0)] })
      draft.values["body"] = id
      try store.save(
        StoredEditorDraft(
          id: id, table: "notes", recordID: recordID, draft: draft, failure: nil, failedPatch: nil))
    }
    let oldFiles = try FileManager.default.contentsOfDirectory(
      at: store.directory, includingPropertiesForKeys: nil)
    let oldBytes = try oldFiles.map { try Data(contentsOf: $0) }
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in
      Issue.record("Installing a copy must not write")
      return [:]
    }
    #expect(editor.recoveryChoices.count == 2)
    try editor.installDuplicateDraft(from: [
      "id": .string("source"), "title": .string("Copy"), "nullable": .null,
    ])
    #expect(editor.recovery == nil)
    let journals = try store.all()
    #expect(journals.count == 4)
    let copy = try #require(
      journals.first { !["old-new-1", "old-new-2", "old-source"].contains($0.id) })
    #expect(copy.recordID == nil && copy.draft.original == nil)
    #expect(copy.draft.patch == ["title": .string("Copy"), "nullable": .null])
    let reopened = RecordEditorModel(
      properties: fields, original: nil, table: "notes", store: store, recovered: copy
    ) { _, _ in
      Issue.record("Recovering a copy must not write")
      return [:]
    }
    reopened.resumeDraft()
    #expect(reopened.isNew && reopened.draft.patch == copy.draft.patch)
    try reopened.discardDraft()
    try editor.discardDraft()
    #expect(try store.all().count == 3)
    #expect(try oldFiles.map { try Data(contentsOf: $0) } == oldBytes)
  }

  @Test func evenAnEmptyCopyIsJournaledBeforePresentation() throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in
      Issue.record("An empty copy must not create a row")
      return [:]
    }
    try editor.installDuplicateDraft(from: ["id": .string("source")])
    let saved = try #require(try store.load(table: "notes", recordID: nil))
    #expect(saved.draft.original == nil && saved.draft.patch.isEmpty)
  }

  @Test func failedPersistenceRollsBackTheCopyAndRecoveryChoices() throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var oldDraft = RecordDraft(properties: fields, original: nil)
    oldDraft.values["title"] = "Keep older draft"
    try store.save(
      StoredEditorDraft(
        id: "old", table: "notes", recordID: nil, draft: oldDraft, failure: nil, failedPatch: nil))
    let oldFiles = try FileManager.default.contentsOfDirectory(
      at: store.directory, includingPropertiesForKeys: nil)
    let oldBytes = try oldFiles.map { try Data(contentsOf: $0) }
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in [:] }
    let backup = store.directory.appendingPathExtension("kept")
    try FileManager.default.moveItem(at: store.directory, to: backup)
    try Data("blocked".utf8).write(to: store.directory)
    #expect(throws: (any Error).self) {
      try editor.installDuplicateDraft(from: [
        "title": .string("Do not publish"), "nullable": .null,
      ])
    }
    #expect(editor.isNew && !editor.dirty && !editor.autosavePaused)
    #expect(editor.draft.patch.isEmpty && editor.draft.values["title"] == "")
    #expect(editor.recoveryChoices.map(\.id) == ["old"])
    #expect(try Data(contentsOf: store.directory) == Data("blocked".utf8))
    #expect(
      try oldFiles.map { try Data(contentsOf: backup.appendingPathComponent($0.lastPathComponent)) }
        == oldBytes)
  }

  @Test func unreadableRecoveryIsNotReplacedByACopy() throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let bad = store.directory.appendingPathComponent("unreadable.json")
    try Data("keep invalid bytes".utf8).write(to: bad)
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in [:] }
    #expect(throws: WorkspaceError.self) {
      try editor.installDuplicateDraft(from: ["title": .string("Copy")])
    }
    #expect(editor.draft.patch.isEmpty)
    #expect(try Data(contentsOf: bad) == Data("keep invalid bytes".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == [
        "unreadable.json"
      ])
  }

  @Test(arguments: ["existing", "dirty", "stale", "recovered existing"])
  func copyCannotReplaceAnExistingOrChangedEditor(_ kind: String) throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let recovered =
      kind == "recovered existing"
      ? StoredEditorDraft(
        id: "old", table: "notes", recordID: "source",
        draft: RecordDraft(properties: fields, original: nil), failure: nil, failedPatch: nil) : nil
    let editor = RecordEditorModel(
      properties: fields, original: kind == "existing" ? ["id": .string("source")] : nil,
      table: "notes", store: store, recovered: recovered
    ) { _, _ in [:] }
    if kind == "dirty" { editor.setValue("Newer typing", for: "title") }
    let before = editor.draft.patch
    #expect(throws: (any Error).self) {
      try editor.installDuplicateDraft(
        from: ["title": .string("Copy")], isCurrent: { kind != "stale" })
    }
    #expect(editor.draft.patch == before)
    #expect(try store.all().count == (kind == "dirty" ? 1 : 0))
  }

  @Test func cancelledCopyCannotPublishOrPersist() async throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in [:] }
    let task = Task { try editor.installDuplicateDraft(from: ["title": .string("Copy")]) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(editor.draft.patch.isEmpty)
    #expect(try store.all().isEmpty)
  }

  @Test(arguments: [false, true])
  func failedSaveRetainsTheNewCopyAndCannotBeReplacedByAnotherCopy(_ empty: Bool) async throws {
    let (root, store) = try storeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: store)
    { _, _ in
      throw WorkspaceError(message: "Synthetic failure", violations: [])
    }
    try editor.installDuplicateDraft(
      from: empty ? ["id": .string("source")] : ["id": .string("source"), "nullable": .null])
    await #expect(throws: WorkspaceError.self) { try await editor.saveAll() }
    let expected: WorkspaceRecord = empty ? [:] : ["nullable": .null]
    #expect(editor.isNew && editor.draft.patch == expected)
    #expect(try store.load(table: "notes", recordID: nil)?.draft.patch == expected)
    #expect(throws: WorkspaceError.self) {
      try editor.installDuplicateDraft(from: ["title": .string("Another")])
    }
  }

  @Test func anInFlightEmptyCreationCannotAcquireAnotherDraft() async throws {
    var pending: CheckedContinuation<WorkspaceRecord, Never>?
    let editor = RecordEditorModel(properties: fields, original: nil, table: "notes", store: nil) {
      _, _ in
      await withCheckedContinuation { pending = $0 }
    }
    let saving = Task { try await editor.saveAll() }
    for _ in 0..<1000 where pending == nil { await Task.yield() }
    let release = try #require(pending)
    #expect(editor.saving && !editor.dirty)
    #expect(throws: WorkspaceError.self) {
      try editor.installDuplicateDraft(from: ["title": .string("Another")])
    }
    #expect(editor.draft.patch.isEmpty)
    release.resume(returning: ["id": .string("created"), "updated_at": .string("revision-1")])
    try await saving.value
  }
}
