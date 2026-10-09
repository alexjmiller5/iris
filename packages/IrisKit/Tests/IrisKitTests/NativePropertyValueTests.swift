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
  @Test @MainActor func cancelledResolutionDoesNotPublishLateLabel() async {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let field = CatalogField(property: ["type": .string("ref"), "ref_table": .string("targets")])
    let task = Task {
      await NativePropertyValue.referenceLabels(field: field, value: "opaque") { _ in
        started.continuation.yield(())
        for await _ in release.stream { break }
        return [WorkspaceRow(record: ["id": .string("opaque")], label: "Late label")]
      }
    }
    for await _ in started.stream { break }
    task.cancel()
    release.continuation.yield(())
    #expect(await task.value == "Unavailable")
  }
  @Test @MainActor func referencesResolveLabelsAndHideMissingIDs() async throws {
    let field = CatalogField(property: [
      "type": .string("multi_ref"), "ref_table": .string("targets"),
    ])
    let labels = await NativePropertyValue.referenceLabels(
      field: field, value: #"["found","missing"]"#
    ) { view in
      #expect(view.table == "targets")
      return [WorkspaceRow(record: ["id": .string("found")], label: "Visible label")]
    }
    #expect(labels == "Visible label, Unavailable")
  }
}
