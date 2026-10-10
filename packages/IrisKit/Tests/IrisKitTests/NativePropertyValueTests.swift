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
