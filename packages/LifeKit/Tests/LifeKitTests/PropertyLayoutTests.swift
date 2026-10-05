import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor
struct PropertyLayoutTests {
  @Test func propertyLayoutPersistsAndNeverProjectsEditableRows() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    try model.applyPropertyLayout(columns: ["status", "body"], context: context)
    #expect(model.visibleRecordColumns == ["status", "body"])
    try await model.saveCurrentView(name: "Compact", update: false, context: context)
    let saved = try #require(try await context.workspace.listViews(table: "notes").views.first)
    #expect(saved.definition?.columns == ["status", "body"])
    try model.applySavedView(nil, context: context)
    #expect(model.visibleRecordColumns == nil)
    try model.applySavedView(saved, context: context)
    #expect(model.visibleRecordColumns == ["status", "body"])
    await model.reload()
    #expect(model.rows.first?.record["title"] != nil)
    #expect(model.rows.first?.record["updated_at"] != nil)
    try model.applyPropertyLayout(columns: [], context: context)
    #expect(model.viewModified)
    #expect(try model.currentViewDefinition().columns == ["title"])
    try model.applyPropertyLayout(columns: nil, context: context)
    #expect(try model.currentViewDefinition().columns == nil)
    await model.close()
  }

  @Test func titleAndSavedOrderKeepAllDraftPropertiesAvailable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    try model.applyPropertyLayout(columns: ["status", "body"], context: context)
    let fields = ["body", "status", "title", "extra"].map {
      CatalogField(property: ["col": .string($0), "type": .string("text")])
    }
    #expect(model.titleProperty?.id == "title")
    #expect(model.orderedRecordFields(fields).map(\.id) == ["title", "status", "body", "extra"])
    #expect(
      model.recordTitle(["id": .string("opaque-id"), "title": .string("  A useful title  ")])
        == "A useful title")
    #expect(model.recordTitle(nil) == "New record")
    #expect(model.recordTitle(["id": .string("opaque-id"), "title": .string(" ")]) == "opaque-id")
    await model.close()
  }

  @Test func titleUsesConfiguredColumnEvenWithoutCatalogProperty() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let catalog = try #require(model.catalog)
    let altered = CoreCatalog(tables: catalog.tables, properties: [], rules: catalog.rules)
    model.catalog = try WorkspaceCatalog(altered)
    #expect(model.titleProperty == nil)
    #expect(
      model.recordTitle(["id": .string("opaque-id"), "title": .string("Readable")]) == "Readable")
    #expect(model.recordTitle(["id": .string("opaque-id"), "title": .bool(false)]) == "false")
    #expect(model.recordTitle(["id": .string("opaque-id"), "title": .number(2.5)]) == "2.5")
    await model.close()
  }

  @Test func titleOnlyViewWithUncatalogedDisplayColumnRemainsValid() async throws {
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    runtime.context.evaluateScript(
      "LifeSql.run(\"DELETE FROM catalog_properties WHERE tbl='notes' AND col='title'\")")
    let model = WorkspaceModel()
    model.client = workspace
    model.catalog = try await workspace.catalog()
    model.table = "notes"
    await model.reload()
    let context = try #require(model.editingContext)
    #expect(model.titleProperty == nil)
    try model.applyPropertyLayout(columns: [], context: context)
    try await model.saveCurrentView(name: "Title only", update: false, context: context)
    #expect(model.appliedView?.definition?.columns == ["id"])
    #expect(model.appliedView?.unavailable == nil)
    #expect(model.recordTitle(model.rows.first?.record) == model.rows.first?.label)
    await model.close()
  }

  @Test func invalidOrStaleLayoutCannotReplaceCurrentSelection() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    try model.applyPropertyLayout(columns: ["status"], context: context)
    for columns in [["gone"], ["status", "status"]] {
      #expect(throws: WorkspaceError.self) {
        try model.applyPropertyLayout(columns: columns, context: context)
      }
      #expect(model.visibleRecordColumns == ["status"])
    }
    model.table = "topics"
    #expect(model.visibleRecordColumns == nil)
    #expect(throws: WorkspaceError.self) {
      try model.applyPropertyLayout(columns: ["status"], context: context)
    }
    await model.close()
  }
}
