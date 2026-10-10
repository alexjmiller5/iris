import Foundation
import Testing

@testable import IrisKit

@MainActor
struct ReferencePickerTests {
  @Test func namedReferenceChoicesWriteIDsAndSurviveReopening() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("references.sqlite").path
    let workspace = try NativeWorkspace(path: path)
    try await workspace.createSample()
    try await workspace.indexSearch()
    let catalog = try await workspace.catalog()
    #expect(
      catalog.properties.contains { $0["col"] == .string("topic") && $0["type"] == .string("ref") })
    let model = try ReferencePickerModel(table: "topics", value: "", multiple: false) {
      try await workspace.rows(view: $0)
    }
    await model.reload()
    let topic = try #require(model.rows.first { $0.label == "Field notes" })
    #expect(topic.id != topic.label)
    model.choose(topic)
    let related = try ReferencePickerModel(table: "topics", value: "", multiple: true) {
      try await workspace.rows(view: $0)
    }
    await related.reload()
    for row in related.rows { related.choose(row) }
    let record = try await workspace.write(
      table: "notes",
      patch: [
        "title": .string("Reference fixture"), "topic": .string(model.selection.value),
        "related": .string(related.selection.value),
      ])
    #expect(record["topic"] == .string(topic.id))
    try await workspace.close()
    let reopened = try NativeWorkspace(path: path)
    let stored = try #require(
      try await reopened.rows(table: "notes", search: "Reference fixture").first)
    #expect(stored.record["topic"] == .string(topic.id))
    let restored = try ReferencePickerModel(
      table: "topics", value: stored.record["related"]?.text ?? "", multiple: true
    ) { try await reopened.rows(view: $0) }
    await restored.resolveSelected()
    #expect(Set(restored.selection.ids) == Set(related.selection.ids))
    #expect(
      Set(restored.selection.ids.map { restored.label(for: $0) }) == ["Field notes", "Ideas"])
    try await reopened.close()
  }

  @Test func lateSearchCannotReplaceNewResultsOrDropSelectedReferences() async throws {
    var oldResponse: CheckedContinuation<[WorkspaceRow], Error>?
    let chosen = WorkspaceRow(record: ["id": .string("chosen-id")], label: "Chosen name")
    let model = try ReferencePickerModel(table: "topics", value: #"["missing-id"]"#, multiple: true)
    { view in
      if view.search == "old" {
        return try await withCheckedThrowingContinuation { oldResponse = $0 }
      }
      return [chosen]
    }
    model.search = "old"
    let old = Task { await model.reload() }
    while oldResponse == nil { await Task.yield() }
    model.search = "new"
    await model.reload()
    model.choose(chosen)
    oldResponse?.resume(returning: [
      WorkspaceRow(record: ["id": .string("stale")], label: "Old result")
    ])
    await old.value
    #expect(model.rows.map(\.label) == ["Chosen name"])
    #expect(model.selection.ids == ["missing-id", "chosen-id"])
    // Unread selections read as loading, never as unavailable, until resolved.
    #expect(model.label(for: "missing-id") == "Loading…")
    #expect(model.label(for: "chosen-id") == "Chosen name")
  }

  @Test func dismissingSearchInvalidatesItsOutstandingResponse() async throws {
    var response: CheckedContinuation<[WorkspaceRow], Error>?
    let model = try ReferencePickerModel(table: "topics", value: "keep", multiple: false) { _ in
      try await withCheckedThrowingContinuation { response = $0 }
    }
    let request = Task { await model.reload() }
    while response == nil { await Task.yield() }
    model.invalidateSearch()
    response?.resume(returning: [WorkspaceRow(record: ["id": .string("late")], label: "Too late")])
    await request.value
    #expect(model.rows.isEmpty)
    #expect(model.selection.value == "keep")
    #expect(!model.loading)
  }

  @Test func changedSearchRejectsAnOldResponseBeforeTheNextTaskStarts() async throws {
    var response: CheckedContinuation<[WorkspaceRow], Error>?
    let model = try ReferencePickerModel(table: "topics", value: "keep", multiple: false) { _ in
      try await withCheckedThrowingContinuation { response = $0 }
    }
    let request = Task { await model.reload() }
    while response == nil { await Task.yield() }
    model.search = "new query"
    response?.resume(returning: [WorkspaceRow(record: ["id": .string("old")], label: "Old query")])
    await request.value
    #expect(model.rows.isEmpty)
    #expect(model.selection.value == "keep")
  }

  @Test func selectedLabelsResolveOutsideTheSearchPageWithoutRewritingIDs() async throws {
    var lookedUp: [String] = []
    let model = try ReferencePickerModel(
      table: "topics", value: #"["missing","existing"]"#, multiple: true
    ) { view in
      #expect(view.table == "topics")
      // One any-of read for the whole selection.
      let ids = (view.groups?.first?.filters ?? []).compactMap { filter -> String? in
        if case .string(let value) = filter.value { return value }
        return nil
      }
      #expect(view.groups?.first?.match == "any")
      lookedUp += ids
      return ids.contains("existing")
        ? [WorkspaceRow(record: ["id": .string("existing")], label: "Named record")] : []
    }
    #expect(model.label(for: "existing") == "Loading…")
    await model.resolveSelected()
    #expect(lookedUp == ["missing", "existing"])
    #expect(model.label(for: "existing") == "Named record")
    #expect(model.label(for: "missing") == "Unavailable")
    #expect(model.selection.value == #"["missing","existing"]"#)
  }

  @Test func missingReferencesStayStoredAndOnlyCarriedOnesAreRejected() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    try await workspace.indexSearch()
    let topic = try #require(try await workspace.rows(table: "topics", search: "Ideas").first)
    let created = try await workspace.write(
      table: "notes",
      patch: [
        "title": .string("Missing reference fixture"), "topic": .string(topic.id),
        "related": .string("[\"\(topic.id)\"]"),
      ])
    _ = try await workspace.write(
      table: "topics", patch: ["id": .string(topic.id), "deleted_at": .bool(true)])
    let catalog = try await workspace.catalog()
    var draft = RecordDraft(
      properties: catalog.properties.filter { $0["tbl"] == .string("notes") }, original: created)
    let picker = try ReferencePickerModel(
      table: "topics", value: draft.values["related"] ?? "", multiple: true
    ) { try await workspace.rows(view: $0) }
    await picker.resolveSelected()
    #expect(picker.label(for: topic.id) == "Unavailable")
    draft.values["title"] = "Unrelated edit"
    #expect(draft.patch["topic"] == nil)
    #expect(draft.patch["related"] == nil)
    // Like the hub, an edit only claims the cells it carries.
    let edited = try await workspace.write(
      table: "notes", patch: draft.patch, expectedUpdatedAt: created["updated_at"]?.text)
    #expect(edited["topic"] == created["topic"])
    #expect(edited["related"] == created["related"])
    do {
      _ = try await workspace.write(
        table: "notes",
        patch: ["id": try #require(created["id"]), "related": try #require(created["related"])],
        expectedUpdatedAt: edited["updated_at"]?.text)
      Issue.record("A carried missing reference was silently accepted")
    } catch let error as WorkspaceError {
      #expect(error.violations.contains { $0.rule == "ref" })
    }
    let stored = try #require(
      try await workspace.rows(table: "notes", search: "Unrelated edit").first)
    #expect(stored.record["topic"] == created["topic"])
    #expect(stored.record["related"] == created["related"])
    #expect(draft.values["related"] == created["related"]?.text)
    try await workspace.close()
  }

  @Test func failedLookupPreservesTheDraftAndReportsTheFailure() async throws {
    let model = try ReferencePickerModel(table: "topics", value: "keep", multiple: false) { _ in
      throw WorkspaceError(message: "Offline fixture", violations: [])
    }
    await model.resolveSelected()
    #expect(model.selection.value == "keep")
    #expect(model.error == "Offline fixture")
    #expect(model.label(for: "keep") == "Unavailable")
  }
}
