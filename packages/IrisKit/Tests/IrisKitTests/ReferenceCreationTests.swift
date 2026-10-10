import Foundation
import Testing

@testable import IrisKit

/// The temporary sample has no hub: every create here is an offline local write.
/// notes.topic (ref) and notes.related (multi_ref) point at topics, named by title.
@MainActor
struct ReferenceCreationTests {
  private func sample(_ topicProperties: [(String, CoreRow)] = []) async throws -> (
    WorkspaceModel, WorkspaceEditingContext
  ) {
    let model = WorkspaceModel()
    await model.open(demo: true)
    await model.searchIndexSettled()  // the index builds in the background after open
    let context = try #require(model.editingContext)
    for (column, fields) in topicProperties {
      _ = try await context.workspace.saveCatalogProperty(
        CoreSaveCatalogPropertyArgs(
          table: "topics", column: column, expectedUpdatedAt: nil, fields: fields, addColumn: true))
    }
    model.catalog = try await context.workspace.catalog()
    return (model, context)
  }

  private func picker(
    _ model: WorkspaceModel, _ context: WorkspaceEditingContext, _ column: String,
    value: String = ""
  ) throws -> ReferencePickerModel {
    let field = try #require(model.properties.map(CatalogField.init).first { $0.id == column })
    return try ReferencePickerModel(
      table: "topics", value: value, multiple: field.type == "multi_ref",
      creator: model.referenceCreator(for: field, context: context)
    ) { try await context.workspace.rows(view: $0) }
  }

  private func topics(_ context: WorkspaceEditingContext) async throws -> [WorkspaceRow] {
    try await context.workspace.rows(table: "topics")
  }

  @Test func creationIsOfferedOnlyForTrimmedTextWithoutAnExactName() async throws {
    let (model, context) = try await sample()
    let picker = try picker(model, context, "topic")
    picker.search = "  Ideas "
    await picker.reload()
    #expect(picker.creationOffer == nil)
    picker.search = "Idea"
    await picker.reload()
    #expect(picker.rows.map(\.label) == ["Ideas"])
    #expect(picker.creationOffer == "Idea")
    picker.search = "   "
    #expect(picker.creationOffer == nil)
    let withoutCreator = try ReferencePickerModel(table: "topics", value: "", multiple: false) {
      try await context.workspace.rows(view: $0)
    }
    withoutCreator.search = "Idea"
    #expect(withoutCreator.creationOffer == nil)
    await model.close()
  }

  @Test func readOnlyTargetsAndDerivedOrMissingNamesAreNotCreatable() {
    let field = CatalogField(
      property: ["col": .string("host"), "type": .string("ref"), "ref_table": .string("people")])
    let table: CoreRow = [
      "id": .string("people"), "display": .string("name"), "readOnly": .bool(false),
    ]
    let name: CoreRow = ["tbl": .string("people"), "col": .string("name"), "type": .string("text")]
    func target(_ table: CoreRow, _ name: CoreRow = name) -> String? {
      ReferenceCreator.target(of: field, tables: [table], properties: [name])?.display
    }
    #expect(target(table) == "name")
    #expect(target(table.merging(["readOnly": .bool(true)]) { $1 }) == nil)
    #expect(target(table.merging(["display": .string("id")]) { $1 }) == nil)
    #expect(target(table.merging(["display": .null]) { $1 }) == nil)
    #expect(target(table, name.merging(["derived_by": .string("http:name")]) { $1 }) == nil)
    #expect(target(table, name.merging(["deprecated": .number(1)]) { $1 }) == nil)
    #expect(target(table.merging(["id": .string("other")]) { $1 }) == nil)
  }

  @Test func directCreateWritesLocallyWithDefaultsAndSelectsTheExactID() async throws {
    let (model, context) = try await sample([
      ("kind", ["type": .string("text"), "default_value": .string("General")])
    ])
    let picker = try picker(model, context, "topic", value: "kept-until-chosen")
    let before = try await topics(context).count
    await picker.create("Field trips")
    #expect(picker.creation == nil)
    #expect(picker.error == nil)
    let created = try #require(try await topics(context).first { $0.label == "Field trips" })
    #expect(created.record["kind"] == .string("General"))
    #expect(try await topics(context).count == before + 1)
    #expect(picker.selection.value == created.id)
    #expect(picker.label(for: created.id) == "Field trips")
    // Undo reverts the creation like any other saved change.
    let action = try #require(model.undoAction)
    #expect(action.table == "topics" && action.rowId == created.id)
    try await model.undo(action, context: context)
    #expect(try await topics(context).count == before)
    await model.close()
  }

  @Test func requiredFieldsHandOffToTheEditorWhichSavesThroughValidation() async throws {
    let (model, context) = try await sample([
      ("code", ["type": .string("text"), "required": .number(1)])
    ])
    let picker = try picker(model, context, "topic")
    let before = try await topics(context).count
    await picker.create("Travel")
    let editor = try #require(picker.creation)
    #expect(editor.isNew)
    #expect(editor.draft.values["title"] == "Travel")
    #expect(try await topics(context).count == before)
    await picker.save(editor)
    #expect(picker.creation === editor)
    #expect(editor.violations.contains { $0.col == "code" })
    #expect(picker.selection.ids.isEmpty)
    editor.setValue("TRV", for: "code")
    await picker.save(editor)
    #expect(picker.creation == nil)
    let created = try #require(try await topics(context).first { $0.label == "Travel" })
    #expect(created.record["code"] == .string("TRV"))
    #expect(picker.selection.value == created.id)
    await model.close()
  }

  @Test func cancellingTheHandOffKeepsTheSelectionAndWritesNothing() async throws {
    let (model, context) = try await sample([
      ("code", ["type": .string("text"), "required": .number(1)])
    ])
    let original = #"["kept"]"#
    let picker = try picker(model, context, "related", value: original)
    let before = try await topics(context).count
    await picker.create("Abandoned")
    picker.creation?.setValue("ABN", for: "code")
    picker.cancelCreation()
    #expect(picker.creation == nil)
    #expect(picker.selection.value == original)
    #expect(try await topics(context).count == before)
    await model.close()
  }

  @Test func multiReferenceCreationAppendsAfterExistingSelections() async throws {
    let (model, context) = try await sample()
    let existing = try #require(try await topics(context).first { $0.label == "Ideas" })
    let picker = try picker(
      model, context, "related",
      value: String(decoding: try JSONEncoder().encode([existing.id]), as: UTF8.self))
    await picker.create("Gardening")
    let created = try #require(try await topics(context).first { $0.label == "Gardening" })
    #expect(picker.selection.ids == [existing.id, created.id])
    #expect(
      try JSONDecoder().decode([String].self, from: Data(picker.selection.value.utf8))
        == [existing.id, created.id])
    await model.close()
  }
}
