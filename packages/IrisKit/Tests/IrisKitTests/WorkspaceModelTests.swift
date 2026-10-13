import Observation
import Testing

@testable import IrisKit

@MainActor
struct WorkspaceModelTests {
  @Test func missingOrClosedWorkspaceCannotReportSaveSuccess() async throws {
    let model = WorkspaceModel()
    await #expect(throws: WorkspaceError.self) {
      try await model.save(["title": .string("Unsaved")], original: nil, context: nil)
    }
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    await model.close()
    await #expect(throws: WorkspaceError.self) {
      try await model.save(["title": .string("Unsaved")], original: nil, context: context)
    }
  }

  @Test func catalogDerivedFieldsFollowTheCatalogAndTable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    func columns() -> [String] { model.properties.compactMap { $0["col"]?.text } }
    func expected() -> Set<String> {
      Set(
        (model.catalog?.properties ?? []).filter { $0["tbl"]?.text == model.table }
          .compactMap { $0["col"]?.text })
    }
    #expect(!columns().isEmpty && Set(columns()) == expected())
    final class Changed: @unchecked Sendable { var value = false }
    // Views reading derived fields still observe the table and catalog behind them.
    let table = Changed()
    withObservationTracking {
      _ = model.properties
    } onChange: {
      table.value = true
    }
    model.table = "history"
    #expect(table.value)
    #expect(Set(columns()) == expected())
    let catalog = try #require(model.catalog)
    let edited = Changed()
    withObservationTracking {
      _ = model.properties
    } onChange: {
      edited.value = true
    }
    model.catalog = try WorkspaceCatalog(
      CoreCatalog(tables: catalog.tables, properties: [], rules: catalog.rules))
    #expect(edited.value)
    #expect(columns().isEmpty && !model.canWrite)
    // A wide replica: every row and column header reads these per render.
    let tables = (0..<40).map { index -> WorkspaceRecord in
      ["id": .string("t\(index)"), "display": .string("c\(index)"), "readOnly": .bool(false)]
    }
    let properties = (0..<1_302).map { index in
      CoreProperty(tbl: "t\(index % 40)", col: "c\(index)", sort: .value(Double(index % 7)))
    }
    model.catalog = try WorkspaceCatalog(
      CoreCatalog(tables: tables, properties: properties, rules: []))
    model.table = "t3"
    let clock = ContinuousClock()
    let started = clock.now
    for _ in 0..<1_000 { _ = model.titleProperty }
    print("catalogDerived properties=1302 titleProperty_x1000=\(started.duration(to: clock.now))")
    #expect(model.titleProperty?.id == "c3")
    await model.close()
  }

  @Test func editorCannotWriteToAnotherWorkspaceWithTheSameTable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    await model.open(demo: true)
    do {
      try await model.save(["title": .string("Must not appear")], original: nil, context: context)
      Issue.record("A stale editor saved into another workspace")
    } catch let error as WorkspaceError {
      #expect(error.message == "The workspace or table changed. Reopen the record before saving.")
    }
    #expect(try await model.client?.rows(table: "notes", search: "Must not appear").isEmpty == true)
    await model.close()
  }

  @Test func editorRejectsTableSelectionChangesBeforeCallingCore() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    model.table = "history"
    do {
      try await model.save(["title": .string("Must not appear")], original: nil, context: context)
      Issue.record("A stale table selection was accepted")
    } catch let error as WorkspaceError {
      #expect(error.message == "The workspace or table changed. Reopen the record before saving.")
    }
    await model.close()
  }

  @Test func draftRecoveryReadsTheCurrentRowEvenWhenItIsOutsideTheLoadedPage() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let original = try #require(model.rows.first?.record)
    let saved = StoredEditorDraft(
      table: "notes", recordID: original["id"]?.text,
      draft: RecordDraft(properties: model.properties, original: original), failure: nil,
      failedPatch: nil)
    _ = try await context.workspace.write(
      table: "notes",
      patch: [
        "id": original["id"]!, "body": .string("Changed outside this editor"),
      ],
      expectedUpdatedAt: original["updated_at"]?.text)
    model.rows = []
    let current = try #require(try await model.recoveryRecord(saved, context: context))
    #expect(current["body"] == .string("Changed outside this editor"))
    #expect(current["updated_at"] != original["updated_at"])
    model.table = "history"
    await #expect(throws: WorkspaceError.self) {
      try await model.recoveryRecord(saved, context: context)
    }
    await model.close()
  }
}
