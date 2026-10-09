import Foundation
import Testing

@testable import IrisKit

// The dedicated JS bundle test checks this fixture against the actual TS entry.
func exportTestSerializer() throws -> RecordExportSerializer {
  let url = try #require(
    Bundle.module.url(
      forResource: "record-export", withExtension: "js", subdirectory: "Fixtures"))
  return RecordExportSerializer(script: try String(contentsOf: url, encoding: .utf8))
}

func exportTestSnapshot() -> RecordExportSnapshot {
  RecordExportSnapshot(
    table: "entries",
    properties: [
      ["tbl": .string("entries"), "col": .string("body"), "type": .string("markdown")],
      ["tbl": .string("entries"), "col": .string("empty"), "type": .string("text")],
    ],
    rows: [
      [
        "id": .string("e\u{301}"), "body": .string("# Raw\r\n\n_tag_  \n雪"),
        "empty": .string(""), "nullable": .null,
      ],
      ["id": .string("\u{e9}"), "body": .string("=2+2"), "empty": .null],
    ],
    scope: .loaded,
    completeness: .init(rows: .unknown, columns: .full, reasons: ["Only loaded rows."]),
    acquisition: .init(
      source: .localReplica, capturedAt: "2026-01-01T00:00:00.000Z", freshness: .unknown,
      lastSync: nil, skippedTables: [], pendingUiEdits: nil, rejectedEdits: nil))
}

private func exportedObject(_ file: RecordExportFile) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
}

struct RecordExportTests {
  @Test func bundledProductionResourceSupportsDefaultSerializer() async throws {
    let snapshot = exportTestSnapshot()
    let bundled = try await RecordExportSerializer().serialize(snapshot, format: .json)
    let fixture = try await exportTestSerializer().serialize(snapshot, format: .json)
    #expect(bundled.files.first?.data == fixture.files.first?.data)
    #expect(bundled.rowCount == 2)
  }

  // Catches synthesized encodeIfPresent dropping unknown status instead of null.
  @Test func unknownStatusIsExplicitNullAndRawRowsAreUnchanged() async throws {
    let artifact = try await exportTestSerializer().serialize(exportTestSnapshot(), format: .json)
    #expect(artifact.rowCount == 2)
    #expect(artifact.files.count == 1)
    let object = try exportedObject(#require(artifact.files.first))
    let rows = try #require(object["rows"] as? [[String: Any]])
    #expect((rows[0]["id"] as? String)?.utf8.elementsEqual("e\u{301}".utf8) == true)
    #expect((rows[1]["id"] as? String)?.utf8.elementsEqual("\u{e9}".utf8) == true)
    #expect(rows[0]["body"] as? String == "# Raw\r\n\n_tag_  \n雪")
    #expect(rows[0]["empty"] as? String == "")
    #expect(rows[0]["nullable"] is NSNull)
    #expect(rows[1]["nullable"] == nil)
    let acquisition = try #require(object["acquisition"] as? [String: Any])
    #expect(acquisition["lastSync"] is NSNull)
    #expect(acquisition["pendingUiEdits"] is NSNull)
    #expect(acquisition["rejectedEdits"] is NSNull)
    #expect(acquisition["freshness"] as? String == "unknown")
    #expect((object["scope"] as? [String: Any])?["kind"] as? String == "loaded")
    #expect((object["completeness"] as? [String: Any])?["rows"] as? String == "unknown")
  }

  @Test func csvAndMetadataKeepOneCapturedIdentity() async throws {
    let artifact = try await exportTestSerializer().serialize(exportTestSnapshot(), format: .csv)
    #expect(artifact.files.count == 2)
    #expect(
      String(decoding: artifact.files[0].data, as: UTF8.self)
        == "\"id\",\"body\",\"empty\",\"nullable\"\r\n"
        + "\"e\u{301}\",\"# Raw\r\n\n_tag_  \n雪\",\"\",\r\n"
        + "\"\u{e9}\",\"'=2+2\",,\r\n")
    let sidecar = try exportedObject(artifact.files[1])
    #expect((sidecar["scope"] as? [String: Any])?["rowCount"] as? Int == 2)
    #expect(
      (sidecar["acquisition"] as? [String: Any])?["capturedAt"] as? String
        == "2026-01-01T00:00:00.000Z")
    #expect((sidecar["csv"] as? [String: Any])?["lossless"] as? Bool == false)
    #expect(sidecar["rows"] == nil)
  }

  @Test func omittedAndEmptySelectionDifferWithoutUnicodeNormalization() async throws {
    let serializer = try exportTestSerializer()
    let snapshot = exportTestSnapshot()
    #expect(try await serializer.serialize(snapshot, format: .json).rowCount == 2)
    #expect(try await serializer.serialize(snapshot, format: .json, selectedIDs: []).rowCount == 0)
    let artifact = try await serializer.serialize(snapshot, format: .json, selectedIDs: ["\u{e9}"])
    let object = try exportedObject(#require(artifact.files.first))
    let rows = try #require(object["rows"] as? [[String: Any]])
    #expect(rows.count == 1)
    #expect((rows[0]["id"] as? String)?.utf8.elementsEqual("\u{e9}".utf8) == true)
    for ids in [["missing"], ["\u{e9}", "\u{e9}"]] {
      await #expect(throws: (any Error).self) {
        try await serializer.serialize(snapshot, format: .json, selectedIDs: ids)
      }
    }
  }

  @Test func unsupportedNumbersFailWithoutPoisoningTheNextCall() async throws {
    let serializer = try exportTestSerializer()
    for number in [-0.0, 9_007_199_254_740_992, Double.infinity, Double.nan] {
      var snapshot = exportTestSnapshot()
      snapshot.rows = [["id": .string("one"), "value": .number(number)]]
      await #expect(throws: (any Error).self) {
        try await serializer.serialize(snapshot, format: .json)
      }
    }
    #expect(try await serializer.serialize(exportTestSnapshot(), format: .json).rowCount == 2)
  }

  @Test func callerMutationCannotChangeAnExportAlreadyStarted() async throws {
    var source = exportTestSnapshot()
    let frozen = source
    source.rows = [["id": .string("new-table-row")]]
    let artifact = try await exportTestSerializer().serialize(frozen, format: .json)
    #expect(artifact.rowCount == 2)
  }

  @Test func quotedSourceIsDataAndInvalidBundleRepliesFail() async throws {
    var snapshot = exportTestSnapshot()
    let body = "'); globalThis.injected = true; //\n<script>throw 1</script>"
    snapshot.rows = [["id": .string("\"\\opaque"), "body": .string(body)]]
    let artifact = try await exportTestSerializer().serialize(snapshot, format: .json)
    let file = try #require(artifact.files.first)
    let rows = try #require(try exportedObject(file)["rows"] as? [[String: Any]])
    #expect(rows[0]["body"] as? String == body)
    for script in [
      "throw new Error('broken')", "globalThis.IrisRecordExport = {}",
      "globalThis.IrisRecordExport = {serialize: () => null}",
      "globalThis.IrisRecordExport = {serialize: () => '{}'}",
    ] {
      await #expect(throws: (any Error).self) {
        try await RecordExportSerializer(script: script).serialize(snapshot, format: .json)
      }
    }
  }

  @MainActor @Test func mainActorCallerCanCancelBeforeSerializationPublishes() async throws {
    let serializer = try exportTestSerializer()
    let task = Task { @MainActor in
      return try await serializer.serialize(exportTestSnapshot(), format: .json)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @MainActor @Test func mainActorCallerUsesTheBackgroundSerializerContext() async throws {
    let artifact = try await exportTestSerializer().serialize(exportTestSnapshot(), format: .json)
    #expect(artifact.rowCount == 2)
  }
}
