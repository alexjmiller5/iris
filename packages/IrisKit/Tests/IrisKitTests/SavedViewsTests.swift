import Foundation
import JavaScriptCore
import Testing

@testable import IrisKit

@MainActor
struct SavedViewsTests {
  #if os(iOS)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_SAVED_VIEWS_SIMULATOR"] != nil)
    )
    func prepareSavedViewsUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(
        environment["IRIS_TEST_SAVED_VIEWS_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      await model.open()
      let client = try #require(model.client)
      for (title, status) in [("Viewfixture Alpha", "Draft"), ("Viewfixture Zulu", "Ready")] {
        _ = try await client.write(
          table: "notes",
          patch: [
            "title": .string(title), "status": .string(status),
            "body": .string("Hidden source for \(title)"),
          ])
      }
      _ = try await client.saveView(
        CoreSaveViewArgs(
          table: "notes", name: "Imported order",
          definition: CoreSavedViewDefinition(
            version: 1, columns: ["status", "title"],
            sort: [CoreSort(column: "title", direction: .desc)], search: "viewfixture",
            widths: ["title": 300])))
      _ = try await client.saveView(
        CoreSaveViewArgs(
          table: "notes", name: "Daily queue",
          definition: CoreSavedViewDefinition(
            version: 2, columns: ["title", "status"],
            filters: [CoreFilter(column: "updated_at", op: .lte, relative: .today)],
            sort: [
              CoreSort(column: "status", direction: .desc, mode: .options),
              CoreSort(column: "title", direction: .asc),
            ], search: "viewfixture",
            groups: [
              CoreFilterGroup(
                match: "any",
                filters: [
                  CoreFilter(column: "status", op: .eq, value: .string("Draft")),
                  CoreFilter(column: "status", op: .eq, value: .string("Other")),
                ])
            ],
            timeZone: "America/New_York",
            actions: [
              CoreRowAction(
                id: "review", label: "Mark reviewed", values: ["status": .string("Ready")])
            ],
            layout: [
              CoreViewLayoutItem(kind: "column", id: "title"),
              CoreViewLayoutItem(kind: "action", id: "review"),
              CoreViewLayoutItem(kind: "column", id: "status"),
            ])))
      await model.close()
    }
  #endif

  @Test func groupedViewsAndActionsKeepTheirMeaningOnNative() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    _ = try await context.workspace.write(
      table: "notes", patch: ["title": .string("Action fixture"), "status": .string("Draft")])
    let definition = CoreSavedViewDefinition(
      version: 2,
      filters: [CoreFilter(column: "title", op: .eq, value: .string("Action fixture"))],
      sort: [
        CoreSort(column: "status", direction: .desc, mode: .options),
        CoreSort(column: "title", direction: .asc),
      ],
      groups: [
        CoreFilterGroup(
          match: "any",
          filters: [
            CoreFilter(column: "status", op: .eq, value: .string("Draft")),
            CoreFilter(column: "status", op: .eq, value: .string("Missing")),
          ])
      ],
      timeZone: "America/New_York",
      actions: [CoreRowAction(id: "review", label: "Review", values: ["status": .string("Ready")])])
    let saved = try await context.workspace.saveView(
      CoreSaveViewArgs(table: "notes", name: "Actions", definition: definition))
    try model.applySavedView(saved, context: context)
    await model.reload()
    let row = try #require(model.rows.first)
    #expect(model.rows.count == 1)
    model.sortAscending = true
    #expect(try model.currentViewDefinition().sort?.first?.mode == .options)
    #expect(try model.currentViewDefinition().sort?.count == 2)
    model.sortAscending = false
    try await model.runRowAction("review", row: row, context: context)
    #expect(model.rows.isEmpty)
    #expect(model.undoAction != nil)
    await #expect(throws: (any Error).self) {
      try await model.runRowAction("review", row: row, context: context)
    }
    #expect(
      try await context.workspace.rows(table: "notes").contains {
        $0.record["status"] == .string("Ready") && $0.id == row.id
      })
    await model.close()
  }

  @Test func receiptCannotReplaceLaterQueryChangesOrAReplacedWorkspace() async throws {
    for transition in ["query", "replace", "closing", "tableRoundTrip"] {
      let runtime = try IrisCoreRuntime()
      let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
      try await client.createSample()
      let model = WorkspaceModel()
      model.client = client
      model.catalog = try await client.catalog()
      model.table = "notes"
      let context = try #require(model.editingContext)
      model.search = "submitted"
      runtime.context.evaluateScript(
        """
        globalThis.originalFinish = __irisFinish;
        globalThis.heldReceipt = null;
        __irisFinish = (id, reply) => { heldReceipt = [id, reply]; };
        """)
      let saving = Task {
        try await model.saveCurrentView(name: "Held receipt", update: false, context: context)
      }
      while runtime.context.objectForKeyedSubscript("heldReceipt")?.isNull != false {
        await Task.yield()
      }
      #expect(model.savingView)
      var closing: Task<Void, Never>?
      if transition == "replace" {
        model.client = nil
        model.table = nil
      } else if transition == "closing" {
        let generation = model.workspaceGeneration
        closing = Task { await model.close() }
        while model.workspaceGeneration == generation { await Task.yield() }
      } else if transition == "tableRoundTrip" {
        model.table = "topics"
        model.table = "notes"
      } else {
        model.search = "later typing"
      }
      runtime.context.evaluateScript(
        "__irisFinish = originalFinish; originalFinish(...heldReceipt);")
      if transition != "query" {
        await #expect(throws: WorkspaceError.self) { try await saving.value }
        await closing?.value
        #expect(model.appliedView == nil)
      } else {
        try await saving.value
        #expect(model.search == "later typing")
        #expect(model.appliedView?.definition?.search == "submitted")
        #expect(model.viewModified)
      }
      #expect(!model.savingView)
      if transition != "closing" { try await client.close() }
    }
  }

  @Test func nativeSavedViewLifecyclePersistsThroughSharedCore() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    let saved = try await workspace.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Ready notes",
        definition: CoreSavedViewDefinition(
          version: 1, filters: [CoreFilter(column: "status", op: .eq, value: .string("Ready"))])))
    #expect(saved.updatedAt != nil)
    #expect(saved.unavailable == nil)
    #expect(try await workspace.listViews(table: "notes").views.map(\.name) == ["Ready notes"])
    let revision = try #require(saved.updatedAt)
    _ = try await workspace.deleteView(
      CoreDeleteViewArgs(id: saved.id, expectedUpdatedAt: revision))
    #expect(try await workspace.listViews(table: "notes").views.isEmpty)
    #expect(try await workspace.rows(table: "views", trash: true).first?.id == saved.id)
    try await workspace.close()
  }

  @Test func applyingImportedViewPreservesLayoutSortAndFullEditableRows() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    await model.searchIndexSettled()  // the index builds in the background after open
    let context = try #require(model.editingContext)
    for (title, status) in [
      ("Zulu fixture", "Draft"), ("Alpha fixture", "Draft"), ("Bravo fixture", "Ready"),
    ] {
      _ = try await context.workspace.write(
        table: "notes",
        patch: [
          "title": .string(title), "status": .string(status),
          "body": .string("Hidden source for \(title)"),
        ])
    }
    let imported = try await context.workspace.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Imported layout",
        definition: CoreSavedViewDefinition(
          version: 1, columns: ["status", "title"],
          sort: [
            CoreSort(column: "status", direction: .asc),
            CoreSort(column: "title", direction: .desc),
          ],
          search: "fixture", widths: ["status": 160, "title": 360])))
    try model.applySavedView(imported, context: context)
    await model.reload()
    #expect(model.rows.map(\.label) == ["Zulu fixture", "Alpha fixture", "Bravo fixture"])
    let row = try #require(model.rows.first)
    #expect(!row.id.isEmpty)
    #expect(row.record["updated_at"] != nil)
    #expect(row.record["body"] == .string("Hidden source for Zulu fixture"))
    #expect(model.visibleRecordColumns == ["status", "title"])
    try model.applyViewOptions(sortColumn: "status", ascending: true, filters: [], context: context)
    try await model.saveCurrentView(name: "Renamed layout", update: true, context: context)
    let persisted = try #require(
      try await context.workspace.listViews(table: "notes").views.first {
        $0.byteExactID == imported.byteExactID
      })
    #expect(persisted.definition?.columns == ["status", "title"])
    #expect(persisted.definition?.widths == ["status": 160, "title": 360])
    #expect(
      persisted.definition?.sort == [
        CoreSort(column: "status", direction: .asc), CoreSort(column: "title", direction: .desc),
      ])
    _ = try await model.save(
      ["id": .string(row.id), "title": .string("Edited full row")], original: row.record,
      context: context)
    let full = try #require(
      try await context.workspace.rows(
        view: CoreView(
          table: "notes", filters: [CoreFilter(column: "id", op: .eq, value: .string(row.id))])
      ).first)
    #expect(full.record["body"] == .string("Hidden source for Zulu fixture"))
    await model.close()
  }

  @Test func refreshedListCannotAdvanceTheAppliedRevision() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    try await model.saveCurrentView(name: "Original view", update: false, context: context)
    let applied = try #require(model.appliedView)
    let appliedRevision: String = try #require(applied.updatedAt)
    let remote = try await context.workspace.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Changed elsewhere",
        definition: CoreSavedViewDefinition(version: 1, search: "remote"),
        id: applied.id, expectedUpdatedAt: appliedRevision))
    try await model.refreshSavedViews(context: context)
    #expect(
      model.savedViews.first { $0.byteExactID == applied.byteExactID }?.updatedAt
        == remote.updatedAt)
    #expect(model.appliedView?.updatedAt == applied.updatedAt)
    await #expect(throws: WorkspaceError.self) {
      try await model.saveCurrentView(name: "Stale update", update: true, context: context)
    }
    await #expect(throws: WorkspaceError.self) {
      try await model.deleteSavedView(applied, context: context)
    }
    #expect(
      try await context.workspace.listViews(table: "notes").views.first {
        $0.byteExactID == applied.byteExactID
      }?.name == "Changed elsewhere")
    try model.applySavedView(remote, context: context)
    try await model.deleteSavedView(remote, context: context)
    #expect(model.appliedView == nil)
    #expect(model.savedViews.map(\.name) == ["Default view"])
    await model.close()
  }

  @Test func staleContextAndUnavailableDefinitionCannotChangeCurrentView() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    model.search = "keep"
    let unavailable = CoreSavedViewRecord(
      id: "broken", name: "Unavailable", tbl: "notes", updatedAt: nil, deletedAt: nil,
      definition: nil, view: nil, unavailable: "A column is unavailable.")
    #expect(throws: WorkspaceError.self) { try model.applySavedView(unavailable, context: context) }
    #expect(model.search == "keep")
    model.table = "topics"
    await #expect(throws: WorkspaceError.self) {
      try await model.saveCurrentView(name: "Wrong table", update: false, context: context)
    }
    #expect(
      try await context.workspace.listViews(table: "notes").views.map(\.name) == ["Default view"])
    await model.close()
  }

  @Test func importedNullAndTypedFiltersKeepTheirMeaningUntilEdited() throws {
    let original = CoreFilter(column: "topic", op: .eq, value: .null)
    var filter = WorkspaceFilter(original)
    let reference = CatalogField(property: ["col": .string("topic"), "type": .string("ref")])
    #expect(try filter.coreFilter(field: reference) == original)
    filter.value = "chosen-id"
    #expect(try filter.coreFilter(field: reference).value == .string("chosen-id"))
    let boolean = WorkspaceFilter(CoreFilter(column: "flag", op: .eq, value: .number(0)))
    #expect(
      try boolean.coreFilter(field: CatalogField(property: ["type": .string("bool")])).value
        == .number(0))
  }

  @Test func importedBooleanFilterCanChangeOperatorWithoutReselectingItsValue() async throws {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    runtime.context.evaluateScript(
      """
      IrisSql.run('ALTER TABLE notes ADD COLUMN flag INTEGER');
      IrisSql.run("INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('notes.flag','notes','flag','bool')");
      """)
    #expect(runtime.context.exception == nil)
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    let field = CatalogField(property: ["col": .string("flag"), "type": .string("bool")])
    for value in [0.0, 1.0] {
      let original = CoreFilter(column: "flag", op: .eq, value: .number(value))
      let saved = try await client.saveView(
        CoreSaveViewArgs(
          table: "notes", name: "Boolean fixture \(value)",
          definition: CoreSavedViewDefinition(version: 1, filters: [original])))
      try model.applySavedView(saved, context: context)
      var filter = try #require(model.filters.first)
      #expect(filter.value == (value == 1 ? "true" : "false"))
      #expect(try filter.coreFilter(field: field) == original)
      filter.operation = .ne
      try model.applyViewOptions(
        sortColumn: "", ascending: true, filters: [filter], context: context)
      #expect(
        try model.currentViewDefinition().filters == [
          CoreFilter(column: "flag", op: .ne, value: .bool(value == 1))
        ])
    }
    await model.close()
  }
}

extension SavedViewsTests {
  @Test func relatedDefaultIsIndependentAndFiltersFullIncomingRecordsThroughRealCore() async throws
  {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let topic = try #require(try await client.rows(table: "topics").first)
    let included = try await client.write(
      table: "notes",
      patch: [
        "title": .string("Linked fixture"), "status": .string("Ready"), "topic": .string(topic.id),
        "body": .string("Complete linked body"),
      ])
    _ = try await client.write(
      table: "notes",
      patch: [
        "title": .string("Excluded fixture"), "status": .string("Draft"),
        "topic": .string(topic.id),
      ])
    let model = WorkspaceModel(credentialStore: MemoryHubCredentials(nil))
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    let ordinary = try await client.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Everyday fixture",
        definition: CoreSavedViewDefinition(
          version: 1, filters: [CoreFilter(column: "status", op: .eq, value: .string("Draft"))])))
    let linked = try await client.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Related fixture",
        definition: CoreSavedViewDefinition(
          version: 1, columns: ["id"],
          filters: [CoreFilter(column: "status", op: .eq, value: .string("Ready"))])))
    try await model.refreshSavedViews(context: context)
    try await model.setDefaultView(ordinary, context: context)
    try await model.setDefaultView(linked, context: context, related: true)
    #expect(model.viewDefault?.viewId == ordinary.id)
    #expect(model.relatedViewDefault?.viewId == linked.id)
    let page = try await client.referencedBy(
      CoreReferencedByArgs(table: "topics", rowId: topic.id, sourceTable: "notes", column: "topic"))
    #expect(page.rows.map(\.id) == [try #require(included["id"]?.text)])
    #expect(page.rows.first?.record["body"] == .string("Complete linked body"))
    let action = try #require(try await client.undoStatus().action)
    _ = try await model.undo(action, context: context)
    #expect(model.relatedViewDefault?.viewId == nil)
    #expect(model.viewDefault?.viewId == ordinary.id)
    await model.close()
  }
  @Test func preferredViewReceiptCannotReplaceTableRoundTripState() async throws {
    let runtime = try IrisCoreRuntime()
    let client = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await client.createSample()
    let model = WorkspaceModel()
    model.client = client
    model.catalog = try await client.catalog()
    model.table = "notes"
    let context = try #require(model.editingContext)
    try await model.refreshSavedViews(context: context)
    let saved = try await client.saveView(
      CoreSaveViewArgs(
        table: "notes", name: "Chosen", definition: CoreSavedViewDefinition(version: 1)))
    runtime.context.evaluateScript(
      "globalThis.originalFinish = __irisFinish; globalThis.heldReceipt = null; __irisFinish = (id, reply) => { heldReceipt = [id, reply]; };"
    )
    let saving = Task { try await model.setDefaultView(saved, context: context) }
    while runtime.context.objectForKeyedSubscript("heldReceipt")?.isNull != false {
      await Task.yield()
    }
    #expect(model.savingView)
    model.table = "topics"
    model.table = "notes"
    runtime.context.evaluateScript("__irisFinish = originalFinish; originalFinish(...heldReceipt);")
    await #expect(throws: WorkspaceError.self) { try await saving.value }
    #expect(model.viewDefault == nil)
    #expect(!model.savingView)
    try await client.close()
  }
}
