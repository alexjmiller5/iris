import Foundation
import Testing

@testable import LifeKit

@MainActor struct CatalogEditorTests {
  @Test func catalogDraftRetainsRejectedInputAndSuccessfulEditsRefreshMetadata() async throws {
    let workspace = WorkspaceModel()
    await workspace.open(demo: true)
    let context = try #require(workspace.editingContext)
    let editor = CatalogEditorModel(workspace: workspace, context: context)
    editor.select(nil, mode: .property)
    editor.key = "review_score"
    editor.fields["type"] = .string("not-a-type")
    editor.fields["description"] = .string("Synthetic review score")
    await editor.save()
    #expect(editor.failure != nil)
    #expect(editor.key == "review_score")
    #expect(editor.fields["description"] == .string("Synthetic review score"))
    #expect(editor.original == nil)
    editor.fields["type"] = .string("number")
    await editor.save()
    #expect(editor.failure == nil)
    #expect(editor.original?["updated_at"]?.text.nonempty != nil)
    #expect(workspace.properties.contains { $0["col"] == .string("review_score") })
    let logs = try await context.workspace.rows(view: CoreView(table: "catalog_log"))
    #expect(logs.count == 1)
    await workspace.close()
  }

  @Test func staleCatalogEditorCannotOverwriteAnotherEditorOrLoseItsDraft() async throws {
    let workspace = WorkspaceModel()
    await workspace.open(demo: true)
    let context = try #require(workspace.editingContext)
    let first = CatalogEditorModel(workspace: workspace, context: context)
    let stale = CatalogEditorModel(workspace: workspace, context: context)
    first.fields["description"] = .string("First saved description")
    await first.save()
    #expect(first.failure == nil)
    stale.fields["description"] = .string("Retain this unsaved description")
    await stale.save()
    #expect(stale.failure?.contains("changed") == true)
    #expect(stale.fields["description"] == .string("Retain this unsaved description"))
    #expect(
      workspace.properties.first { $0["id"] == first.original?["id"] }?["description"]
        == .string("First saved description"))
    await workspace.close()
  }
}
