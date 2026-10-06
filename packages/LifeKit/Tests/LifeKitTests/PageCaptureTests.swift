import CryptoKit
import Foundation
import Testing

@testable import LifeKit

// Generic success row from page-archiver capture-metadata-v1.json at bea8f7f.
// Fixture SHA256 c935010d9e23db71984eb83483c153e05c98998dbda74fb13f183bec01bc1967.
func captureRecord() throws -> WorkspaceRecord {
  try JSONDecoder().decode(
    WorkspaceRecord.self,
    from: Data(
      #"""
      {
        "id":"11111111-1111-4111-8111-111111111111",
        "capture_id":"22222222-2222-5222-8222-222222222222",
        "event_id":"33333333333333333333333333333333",
        "subscription_id":"44444444-4444-4444-8444-444444444444",
        "source_table":"articles","source_row_id":"source-1","source_column":"url",
        "source_url":"https://example.test/article",
        "observed_source_revision":"{\"hub_at\":\"2026-01-01T00:00:00.001Z\",\"updated_at\":\"2026-01-01T00:00:00.000Z\"}",
        "attempted_at":"2026-01-01T00:00:01.000Z",
        "captured_at":"2026-01-01T00:00:02.000Z","status":"succeeded",
        "failure_code":null,"failure_detail":null,
        "created_at":"2026-01-01T00:00:01.000Z","updated_at":"2026-01-01T00:00:02.000Z",
        "deleted_at":null,
        "html_key":"captures/22222222-2222-5222-8222-222222222222/11111111-1111-4111-8111-111111111111/page.html",
        "html_mime":"text/html","html_bytes":17,
        "html_sha256":"74c7835231c92b40bf6415ed21bb8e9cacfb624f16b8a15510a3984874594aa6",
        "png_key":"captures/22222222-2222-5222-8222-222222222222/11111111-1111-4111-8111-111111111111/page.png",
        "png_mime":"image/png","png_bytes":100,
        "png_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
      """#.utf8))
}

func captureWithBytes(_ bytes: Data, kind: String = "html") throws -> PageCapture {
  var row = try captureRecord()
  row[kind + "_bytes"] = .number(Double(bytes.count))
  row[kind + "_sha256"] = .string(
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
  return try PageCapture(record: row)
}

struct PageCaptureTests {
  // Catches normalizing IDs or re-deriving keys from a table/prefix convention.
  @Test func explicitAttemptPreservesOpaqueIdentityAndHistoricalSource() throws {
    var row = try captureRecord()
    row["id"] = .string("e\u{301}")
    row["source_table"] = .string("custom_articles")
    row["html_key"] = .string("another namespace/literal%2Fname.html")
    let attempt = try PageCapture(record: row)
    #expect(attempt.id.utf8.elementsEqual("e\u{301}".utf8))
    #expect(attempt.sourceTable == "custom_articles")
    #expect(try attempt.artifact(.html).key == "another namespace/literal%2Fname.html")
    #expect(attempt.capturedAt == "2026-01-01T00:00:02.000Z")
    #expect(attempt.sourceURL?.absoluteString == "https://example.test/article")
    row["id"] = .string("later-attempt")
    #expect(attempt.id.utf8.elementsEqual("e\u{301}".utf8))
  }

  // The publisher preserves invalid URL text on unsupported attempts, not a new destination.
  @Test(arguments: [
    "ftp://example.test/archive", "not a URL", "https://[invalid",
    "javascript:alert(1)", " e\u{301} / original text ",
  ])
  func unsupportedInvalidURLPreservesHistoricalSource(source: String) throws {
    var row = try captureRecord()
    row["source_url"] = .string(source)
    row["status"] = .string("unsupported")
    row["failure_code"] = .string("invalid_url")
    row["failure_detail"] = .string("Source URL is unsupported")
    row["captured_at"] = .null
    for kind in ["html", "png"] {
      for field in ["key", "mime", "bytes", "sha256"] { row[kind + "_" + field] = .null }
    }
    let attempt = try PageCapture(record: row)
    #expect(attempt.originalURL.utf8.elementsEqual(source.utf8))
    #expect(attempt.sourceURL == nil)
    #expect(attempt.status == .unsupported)
    #expect(attempt.failureCode == "invalid_url")
    #expect(attempt.capturedAt == nil)
    #expect(!attempt.canDownload(.html) && !attempt.canDownload(.png))
    #expect(throws: PageCaptureError.artifactUnavailable) { try attempt.artifact(.png) }
  }

  // Catches legacy failed/partial-code being treated as a retained partial archive.
  @Test(arguments: ["failed", "blocked", "unsupported"])
  func terminalFailureNeverProvidesArtifacts(status: String) throws {
    var row = try captureRecord()
    row["status"] = .string(status)
    row["failure_code"] = .string("partial")
    row["captured_at"] = .null
    for kind in ["html", "png"] {
      for field in ["key", "mime", "bytes", "sha256"] { row[kind + "_" + field] = .null }
    }
    let failed = try PageCapture(record: row)
    #expect(throws: PageCaptureError.self) { try failed.artifact(.png) }
    #expect(failed.sourceURL?.absoluteString == "https://example.test/article")
    row["html_key"] = .string("old/page.html")
    #expect(throws: PageCaptureError.self) { try PageCapture(record: row) }
  }

  @Test(arguments: [
    ("Incomplete archive: 1 resource requests could not be saved.", 1, 0),
    ("Incomplete archive: 1 section was still loading.", 0, 1),
    ("Incomplete archive: 2 sections were still loading.", 0, 2),
    (
      "Incomplete archive: 2 resource requests could not be saved; 1 section was still loading.", 2,
      1
    ),
  ])
  func partialWarningCountsArePreserved(message: String, resources: Int, sections: Int) throws {
    var row = try captureRecord()
    row["status"] = .string("partial")
    row["failure_code"] = .string("partial")
    row["failure_detail"] = .string(message)
    let attempt = try PageCapture(record: row)
    #expect(attempt.warning?.message == message)
    #expect(attempt.warning?.missingResources == resources)
    #expect(attempt.warning?.unfinishedSections == sections)
    #expect(try attempt.artifact(.png).mime == "image/png")
  }

  @Test(arguments: [
    "", "Incomplete archive: .", "Incomplete archive: 0 resource requests could not be saved.",
    "Incomplete archive: -1 sections were still loading.",
    "Incomplete archive: 1 sections were still loading.",
    "Incomplete archive: 2 resource requests could not be saved. <script>bad()</script>",
  ])
  func malformedPartialWarningsAreRejected(message: String) throws {
    var row = try captureRecord()
    row["status"] = .string("partial")
    row["failure_code"] = .string("partial")
    row["failure_detail"] = .string(message)
    #expect(throws: PageCaptureError.self) { try PageCapture(record: row) }
  }

  @Test func pairedArtifactsAndRequiredIntegrityMetadataFailClosed() throws {
    for field in [
      "captured_at", "id", "source_row_id", "html_key", "html_mime", "html_bytes", "html_sha256",
      "png_sha256",
    ] {
      var row = try captureRecord()
      row[field] = nil
      #expect(throws: PageCaptureError.self) { try PageCapture(record: row) }
    }
    let invalid: [(String, CoreJSONValue)] = [
      ("png_mime", .string("text/html")), ("html_bytes", .number(0)),
      ("html_bytes", .number(2.5)), ("html_bytes", .number(.infinity)),
      ("html_sha256", .string(String(repeating: "A", count: 64))),
      ("html_key", .string("a/../secret")), ("status", .string("running")),
      ("source_url", .string("")), ("source_url", .number(1)),
      ("failure_detail", .string("Not success")),
    ]
    for (field, value) in invalid {
      var row = try captureRecord()
      row[field] = value
      #expect(throws: PageCaptureError.self) { try PageCapture(record: row) }
    }
  }

  @Test(arguments: [
    "javascript:alert(1)", "https://user:password@example.test/", "https://example.test/a\nb",
  ])
  func unavailableOriginalActionDoesNotChangeRetainedArtifactValidation(source: String) throws {
    var row = try captureRecord()
    row["source_url"] = .string(source)
    let attempt = try PageCapture(record: row)
    #expect(attempt.originalURL.utf8.elementsEqual(source.utf8))
    #expect(attempt.sourceURL == nil)
    #expect(try attempt.artifact(.html).bytes == 17)
    row["png_sha256"] = .null
    #expect(throws: PageCaptureError.invalidMetadata) { try PageCapture(record: row) }
  }

  // Isolate the byte-count check: a matching digest must not mask a false declared size.
  @Test func matchingDigestDoesNotOverrideDeclaredByteCount() async throws {
    var row = try captureRecord()
    row["html_bytes"] = .number(1)
    row["html_sha256"] = .string(
      SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())
    let attempt = try PageCapture(record: row)
    let file = try RetainedFile(data: Data(), contentType: "text/html", name: "page.html")
    defer { file.dispose() }
    await #expect(throws: PageCaptureError.integrityMismatch) {
      _ = try await attempt.loadArtifact(.html, maximumBytes: 1024) { _, _ in file }
    }
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
  }

  // Size policy must not erase a valid archive or its separate download action.
  @Test func largeValidCaptureRemainsAvailableBeyondPreviewBudget() async throws {
    var row = try captureRecord()
    row["png_bytes"] = .number(128 * 1024 * 1024)
    let attempt = try PageCapture(record: row)
    #expect(try attempt.artifact(.png).bytes == 128 * 1024 * 1024)
    await #expect(throws: PageCaptureError.previewUnavailable) {
      _ = try await attempt.loadArtifact(.png, maximumBytes: 8 * 1024 * 1024) { _, _ in
        Issue.record("Over-budget preview must refuse before a network request")
        throw CancellationError()
      }
    }
    #expect(attempt.canDownload(.png))
    row["png_bytes"] = .number(250 * 1024 * 1024)
    let larger = try PageCapture(record: row)
    #expect(!larger.canDownload(.png))
    #expect(larger.sourceURL == attempt.sourceURL)
  }

  // The fake is only the remote boundary; real bytes, hashing and private files are used.
  @Test func verifiedDownloadReturnsExactBytesAndRejectsMIMECountOrDigestMismatch() async throws {
    let data = Data("<p>stored\r\n雪</p>".utf8)
    let attempt = try captureWithBytes(data)
    let file = try await attempt.loadArtifact(.html, maximumBytes: 1024) { key, limit in
      #expect(key.hasSuffix("/page.html"))
      #expect(limit == data.count)
      return try RetainedFile(data: data, contentType: "text/html", name: "page.html")
    }
    defer { file.dispose() }
    #expect(try Data(contentsOf: file.url) == data)
    for (bytes, mime) in [
      (data, "image/png"), (Data(), "text/html"),
      (Data(repeating: 88, count: data.count), "text/html"),
    ] {
      let bad = try RetainedFile(data: bytes, contentType: mime, name: "page.html")
      await #expect(throws: PageCaptureError.self) {
        _ = try await attempt.loadArtifact(.html, maximumBytes: 1024) { _, _ in bad }
      }
      #expect(!FileManager.default.fileExists(atPath: bad.url.path))
    }
  }
}
