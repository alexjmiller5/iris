import Foundation
import Testing

@testable import IrisKit

struct NativePropertyValueTests {
  @Test func humanScalarValuesPreserveUnknownSource() {
    #expect(NativePropertyValue.text(type: "bool", value: "1") == "Yes")
    #expect(NativePropertyValue.text(type: "bool", value: "false") == "No")
    #expect(NativePropertyValue.text(type: "bool", value: JSONValue.number(0).text) == "No")
    #expect(NativePropertyValue.text(type: "bool", value: JSONValue.number(1).text) == "Yes")
    #expect(NativePropertyValue.text(type: "bool", value: "unknown") == "unknown")
    #expect(
      NativePropertyValue.text(type: "multi_select", value: #"["First","Second"]"#)
        == "First, Second")
    #expect(
      NativePropertyValue.text(type: "multi_select", value: #"["First",2]"#) == #"["First",2]"#)
    #expect(NativePropertyValue.text(type: "date", value: "2024-02-30") == "2024-02-30")
    #expect(NativePropertyValue.text(type: "ref", value: "Named target") == "Unavailable")
  }
  @Test func wholeNumbersReadLikeJavaScript() {
    #expect(JSONValue.number(1).text == "1")
    #expect(JSONValue.number(-3).text == "-3")
    #expect(JSONValue.number(0).text == "0")
    #expect(JSONValue.number(2.5).text == "2.5")
    #expect(JSONValue.number(9_007_199_254_740_991).text == "9007199254740991")
    #expect(JSONValue.number(1e300).text == "1e+300")
  }
  @Test func flagsAreBooleansAndZeroOneInts() {
    func field(_ type: String, _ options: [String]? = nil) -> CatalogField {
      var property: WorkspaceRecord = ["col": .string("c"), "type": .string(type)]
      if let options { property["options"] = .array(options.map { .object(["v": .string($0)]) }) }
      return CatalogField(property: property)
    }
    #expect(field("bool").isFlag)
    #expect(field("int", ["0", "1"]).isFlag)
    #expect(field("int", ["1", "0"]).isFlag)
    for other in [field("int"), field("int", ["0", "1", "2"]), field("number", ["0", "1"])] {
      #expect(!other.isFlag)
    }
    for yes in ["1", "1.0", "true", JSONValue.number(1).text] {
      #expect(NativePropertyValue.flagValue(yes) == true)
    }
    for no in ["0", "0.0", "false"] { #expect(NativePropertyValue.flagValue(no) == false) }
    for unknown in ["", "2", "yes"] { #expect(NativePropertyValue.flagValue(unknown) == nil) }
  }
  @Test func jsonListsAreChipsAndObjectsReadAsText() {
    #expect(
      NativePropertyValue.choiceValues(type: "json", value: #"["Alpha", "Beta", 3, true]"#)
        == ["Alpha", "Beta", "3", "true"])
    for value in [#"{"a":1}"#, #"[{"a":1}]"#, #"[["x"]]"#, "not json", "[]"] {
      #expect(NativePropertyValue.choiceValues(type: "json", value: value) == nil)
    }
    #expect(
      NativePropertyValue.text(type: "json", value: #"{"checking": 12.5, "note": "ok"}"#)
        == "checking: 12.5, note: ok")
    #expect(
      NativePropertyValue.text(type: "json", value: #"{"cover": null, "kind": "list"}"#)
        == "kind: list")
    #expect(NativePropertyValue.text(type: "json", value: #"[{"a":1},{"b":2}]"#) == "2 items")
    #expect(NativePropertyValue.text(type: "json", value: #"[{"a":1}]"#) == "1 item")
    #expect(NativePropertyValue.text(type: "json", value: "[]") == "Not set")
    #expect(NativePropertyValue.text(type: "json", value: "not json {") == "not json {")
  }
  @Test @MainActor func emptyListsOnlyInviteCreationWhenAllowed() {
    #expect(
      WorkspaceView.emptyRecordsMessage(filtered: false, trash: false, canCreate: true)
        == "Create a record to get started.")
    #expect(
      WorkspaceView.emptyRecordsMessage(filtered: false, trash: false, canCreate: false)
        == "This table has no records yet.")
    #expect(
      WorkspaceView.emptyRecordsMessage(filtered: false, trash: true, canCreate: true)
        == "Deleted records appear here.")
    #expect(
      WorkspaceView.emptyRecordsMessage(filtered: true, trash: true, canCreate: true)
        == "Try a different search or filter.")
  }
  @Test func tableNamesWrapAfterUnderscores() {
    #expect(
      "people_sync_observations".wrappingAtUnderscores == "people_\u{200B}sync_\u{200B}observations"
    )
    #expect("tasks".wrappingAtUnderscores == "tasks")
  }
  @Test func datesUseStrictParsingAndUTC() throws {
    let locale = Locale(identifier: "en_US")
    let date = NativePropertyValue.text(type: "date", value: "2024-02-29", locale: locale)
    #expect(date.contains("Feb") && date.contains("29") && date.contains("2024"))
    let instant = NativePropertyValue.text(
      type: "datetime", value: "2024-02-29T00:04:00.000Z", locale: locale)
    #expect(instant.contains("29") && instant.contains("12:04") && instant.hasSuffix(" UTC"))
  }
  @Test @MainActor func referenceIdentityTracksContextAndExactValues() {
    let field = CatalogField(property: [
      "tbl": .string("source"), "col": .string("relation"), "type": .string("ref"),
      "ref_table": .string("targets"),
    ])
    let first = NativePropertyValue.referenceID(field: field, value: "one", workspace: nil)
    #expect(first != NativePropertyValue.referenceID(field: field, value: "two", workspace: nil))
    for key in ["tbl", "col", "type", "ref_table"] {
      var property = field.property
      property[key] = .string("different")
      #expect(
        first
          != NativePropertyValue.referenceID(
            field: CatalogField(property: property), value: "one", workspace: nil))
    }
    #expect(
      NativePropertyValue.referenceID(field: field, value: "é", workspace: nil)
        != NativePropertyValue.referenceID(field: field, value: "e\u{301}", workspace: nil))
  }
  @Test @MainActor func cancelledResolutionDoesNotPublishLateLabel() async throws {
    let workspace = try await sampleWorkspace()
    let note = try #require(try await workspace.rows(table: "notes").first)
    let field = CatalogField(property: ["type": .string("ref"), "ref_table": .string("notes")])
    let task = Task {
      await NativePropertyValue.referenceLabels(field: field, value: note.id, workspace: workspace)
    }
    task.cancel()
    #expect(await task.value == "Unavailable")
    try await workspace.close()
  }
  @Test @MainActor func referencesResolveLabelsAndHideMissingAndTrashedIDs() async throws {
    let workspace = try await sampleWorkspace()
    let live = try #require(try await workspace.rows(table: "notes").first)
    let created = try await workspace.write(
      table: "notes", patch: ["title": .string("Trashed target")], expectedUpdatedAt: nil)
    let trashed = try #require(created["id"]?.text)
    _ = try await workspace.write(
      table: "notes", patch: ["id": .string(trashed), "deleted_at": .bool(true)],
      expectedUpdatedAt: created["updated_at"]?.text)
    let field = CatalogField(property: [
      "type": .string("multi_ref"), "ref_table": .string("notes"),
    ])
    let value = String(
      decoding: try JSONEncoder().encode([live.id, "missing", trashed]), as: UTF8.self)
    #expect(
      await NativePropertyValue.referenceLabels(field: field, value: value, workspace: workspace)
        == "\(live.label), Unavailable, Unavailable")
    #expect(
      await NativePropertyValue.referenceLabels(field: field, value: "[]", workspace: workspace)
        == "Not set")
    try await workspace.close()
  }
  @Test @MainActor func cellsRenderedTogetherShareOneLabelRead() async throws {
    let runtime = try IrisCoreRuntime()
    let workspace = try NativeWorkspace(path: ":memory:", runtime: runtime)
    try await workspace.createSample()
    let notes = try await workspace.rows(table: "notes")
    runtime.context.evaluateScript(
      #"""
      globalThis.labelTrace = [];
      const traced = IrisNative.request;
      IrisNative.request = function(id, method, args) { labelTrace.push(method); return traced(id, method, args); };
      """#)
    let field = CatalogField(property: ["type": .string("ref"), "ref_table": .string("notes")])
    let cells = (0..<60).map { index in
      Task {
        await NativePropertyValue.referenceLabels(
          field: field, value: notes[index % notes.count].id, workspace: workspace)
      }
    }
    for (index, cell) in cells.enumerated() {
      #expect(await cell.value == notes[index % notes.count].label)
    }
    #expect(
      runtime.context.evaluateScript("labelTrace")?.toArray() as? [String] == ["mentionLabels"])
    try await workspace.close()
  }
  @MainActor private func sampleWorkspace() async throws -> NativeWorkspace {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    return workspace
  }
}
