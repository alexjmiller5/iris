import Foundation
import Testing

@testable import LifeKit

@MainActor
struct RecordResolveTests {
  let properties: [WorkspaceRecord] = [
    ["col": .string("title"), "type": .string("text")],
    ["col": .string("computed"), "type": .string("text"), "derived_by": .string("{}")],
  ]
  let original: WorkspaceRecord = [
    "id": .string("fixture"), "title": .string("Original"),
    "computed": .string("Old"), "updated_at": .string("revision-1"),
  ]
  func editor(original: WorkspaceRecord? = nil) -> RecordEditorModel {
    RecordEditorModel(
      properties: properties, original: original ?? self.original,
      table: "examples", store: nil
    ) { _, _ in
      Issue.record("Resolve must never implicitly save a draft")
      return self.original
    }
  }
  @Test func cleanResolutionUsesReadbackAndKeepsDerivedFieldReadOnly() async throws {
    let editor = editor()
    let receipt = original.merging([
      "computed": .string("Resolved"), "updated_at": .string("revision-2"),
    ]) { _, new in new }
    try await editor.resolveDerived { baseline in
      #expect(baseline == original)
      #expect(editor.saving)
      return RecordResolution(record: receipt, failures: [])
    }
    #expect(editor.draft.original == receipt)
    #expect(!editor.dirty && !editor.saving)
    #expect(!editor.draft.fields.contains { $0.id == "computed" })
  }
  @Test func unsavedAndCollectedDraftsNeverReachProvider() async throws {
    for collect in [false, true] {
      let editor = editor()
      if !collect { editor.setValue("Keep this", for: "title") }
      await #expect(throws: WorkspaceError.self) {
        try await editor.resolveDerived(collect: {
          if collect { editor.setValue("Keep this", for: "title") }
        }) { _ in
          Issue.record("Dirty record reached provider")
          return RecordResolution(record: original, failures: [])
        }
      }
      #expect(editor.draft.values["title"] == "Keep this")
      #expect(editor.dirty && !editor.saving)
    }
  }
  @Test func lateTypingSurvivesResolvedReadback() async throws {
    let editor = editor()
    let receipt = original.merging([
      "title": .string("Hub title"), "computed": .string("Resolved"),
      "updated_at": .string("revision-2"),
    ]) { _, new in new }
    try await editor.resolveDerived { _ in
      editor.setValue("Later input", for: "title")
      return RecordResolution(record: receipt, failures: [])
    }
    #expect(editor.draft.values["title"] == "Later input")
    #expect(editor.draft.original == receipt)
    #expect(editor.dirty)
  }
  @Test func providerFailureIsVisibleWithActualReadback() async throws {
    let editor = editor()
    try await editor.resolveDerived { _ in
      RecordResolution(
        record: original,
        failures: [
          CoreDerivationFailure(id: "fixture", col: "computed", error: "Provider unavailable")
        ])
    }
    #expect(editor.failure?.contains("Provider unavailable") == true)
    #expect(editor.draft.original == original)
    #expect(!editor.saving)
  }
  @Test func staleContextAndWrongIdentityNeverReplaceDraft() async throws {
    for wrongID in [false, true] {
      let editor = editor()
      var current = true
      await #expect(throws: WorkspaceError.self) {
        try await editor.resolveDerived(isCurrent: { current }) { _ in
          if !wrongID { current = false }
          return RecordResolution(
            record: original.merging(["id": .string(wrongID ? "other" : "fixture")]) { _, new in new
            }, failures: [])
        }
      }
      #expect(editor.draft.original == original)
      #expect(!editor.saving)
    }
  }
}
