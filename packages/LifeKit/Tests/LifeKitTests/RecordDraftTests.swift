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

  @Test func receiptKeepsLaterTypingAndTheOriginalFieldSet() {
    var draft = RecordDraft(
      properties: properties,
      original: [
        "id": .string("fixture-1"), "title": .string("Original"), "body": .string("Old"),
        "updated_at": .string("revision-1"),
      ])
    draft.values["body"] = "Sent"
    let sent = draft.patch
    draft.values["body"] = "Later typing"
    draft.values["title"] = "Unsaved title"
    draft.values["unknown"] = "Retain recovery source"
    draft.acknowledge(
      [
        "id": .string("fixture-1"), "title": .string("Original"), "body": .string("Sent"),
        "new_column": .string("Server default"), "updated_at": .string("revision-2"),
      ], sent: sent)
    #expect(draft.fields.map(\.id) == ["title", "body"])
    #expect(draft.values["unknown"] == "Retain recovery source")
    #expect(draft.original?["updated_at"] == .string("revision-2"))
    #expect(
      draft.patch == [
        "id": .string("fixture-1"), "title": .string("Unsaved title"),
        "body": .string("Later typing"),
      ])
    draft.values["body"] = "Sent"
    draft.values["title"] = "Original"
    #expect(draft.patch == ["id": .string("fixture-1")])
  }

  @Test func acknowledgedSQLiteBooleanKeepsPickerValueAndCleanPatch() {
    var draft = RecordDraft(
      properties: [["col": .string("done"), "type": .string("bool")]],
      original: ["id": .string("fixture"), "done": .number(1)])
    draft.values["done"] = "false"
    draft.acknowledge(["id": .string("fixture"), "done": .number(0)], sent: draft.patch)
    #expect(draft.values["done"] == "false")
    #expect(draft.patch == ["id": .string("fixture")])
  }
}
