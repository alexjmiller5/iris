import Testing

@testable import LifeKit

struct RecordDraftTests {
  let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text"), "required": .number(1)],
    ["col": .string("body"), "type": .string("markdown")],
    ["col": .string("computed"), "derived_by": .string("derive")],
    ["col": .string("fixed"), "immutable": .number(1)],
    ["col": .string("created_at"), "type": .string("datetime")],
  ]
  @Test func editsOnlyChangedEditableFieldsAndPreservesMarkdown() {
    let original: WorkspaceRecord = [
      "id": .string("fixture-1"), "title": .string("Keep"), "body": .string("# Old"),
      "fixed": .string("keep"), "computed": .string("keep"),
    ]
    var draft = RecordDraft(properties: properties, original: original)
    draft.values["body"] = "# New\n\n**source**\n"
    draft.values["computed"] = "must not write"
    draft.values["fixed"] = "must not write"
    #expect(draft.patch == ["id": .string("fixture-1"), "body": .string("# New\n\n**source**\n")])
  }
  @Test func booleanDraftReflectsSQLiteValues() {
    let fields: [WorkspaceRecord] = [["col": .string("done"), "type": .string("bool")]]
    var draft = RecordDraft(
      properties: fields, original: ["id": .string("fixture-1"), "done": .number(1)])
    #expect(draft.values["done"] == "true")
    draft.values["done"] = "false"
    #expect(draft.patch["done"] == .bool(false))
  }
  @Test func explicitClearBecomesNullWhileNewEmptyFieldsUseCoreDefaults() {
    var draft = RecordDraft(
      properties: properties, original: ["id": .string("fixture-1"), "body": .string("old")])
    draft.values["body"] = ""
    #expect(draft.patch == ["id": .string("fixture-1"), "body": .null])
    let new = RecordDraft(properties: properties, original: nil)
    #expect(new.patch.isEmpty)
    #expect(new.fields.map(\.id) == ["title", "body", "fixed"])
  }
}
