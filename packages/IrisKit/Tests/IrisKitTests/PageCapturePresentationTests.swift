import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import Testing

@testable import IrisKit

@MainActor
struct PageCapturePresentationTests {
  @Test func htmlPreviewUsesVerifiedArtifactAndClosesOnDismissal() async throws {
    let bytes = Data("<!doctype html><h1>Readable archive</h1>".utf8)
    let model = PageCapturePresentation(attempt: try captureWithBytes(bytes)) { _, _ in
      try RetainedFile(data: bytes, contentType: "text/html", name: "page.html")
    }
    defer { model.cancel() }
    await model.startPreview(.html)?.value
    let renderer = try #require(model.htmlRenderer)
    #expect(renderer.webView.configuration.websiteDataStore.isPersistent == false)
    #expect(!renderer.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    #expect(model.previewData == nil && !model.isLoading && model.error == nil)
    model.cancel()
    #expect(model.htmlRenderer == nil && model.file == nil)
  }

  @Test func previewActionProducesBoundedRasterFromVerifiedPNG() async throws {
    let bytes = try capturePNGBytes()
    let model = PageCapturePresentation(attempt: try captureWithBytes(bytes, kind: "png")) { _, _ in
      try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    defer { model.cancel() }
    let action = try #require(model.startPreview())
    #expect(model.isLoading)
    await action.value
    let data = try #require(model.previewData)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 2 && image.height == 1)
    #expect(model.error == nil && !model.isLoading)
  }

  @Test func saveKeepsExactOriginalAndAllowsCancelThenRetry() async throws {
    let bytes = Data("<html><p>é e\u{301} 🐋</p></html>".utf8)
    let model = PageCapturePresentation(attempt: try captureWithBytes(bytes)) { _, _ in
      try RetainedFile(data: bytes, contentType: "text/html", name: "page.html")
    }
    defer { model.cancel() }
    var document: PageCaptureDocument?
    let first = try #require(model.startSave(.html) { document = $0 })
    #expect(model.isLoading)
    await first.value
    #expect(document?.data == bytes)
    #expect(document?.kind == .html)
    #expect(model.isSaving)
    #expect(model.startSave(.png) { _ in Issue.record("Duplicate Save") } == nil)
    // macOS fileExporter may dismiss Cancel without invoking onCompletion.
    model.saveDismissed()
    #expect(!model.isSaving && model.error == nil)
    document = nil
    let retry = try #require(model.startSave(.html) { document = $0 })
    await retry.value
    #expect(document?.data == bytes)
    model.saveCompleted(.failure(CocoaError(.fileWriteNoPermission)))
    #expect(!model.isSaving && model.error != nil)
    model.saveDismissed()
    #expect(model.error != nil, "Dismissal must not erase a reported save failure")
  }

  @Test func undecodablePNGRefusesPreviewButCanSaveVerifiedOriginal() async throws {
    let bytes = Data("synthetic unsupported raster bytes".utf8)
    let attempt = try captureWithBytes(bytes, kind: "png")
    let model = PageCapturePresentation(attempt: attempt) { _, _ in
      try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    defer { model.cancel() }
    let preview = try #require(model.startPreview())
    await preview.value
    #expect(model.previewData == nil && model.unavailableReason != nil)
    #expect(model.error == nil && model.attempt.canDownload(.png))
    var saved: PageCaptureDocument?
    let save = try #require(model.startSave(.png) { saved = $0 })
    await save.value
    #expect(saved?.data == bytes && saved?.kind == .png)
    #expect(model.isSaving)
    model.saveDismissed()
  }

  @Test func dismissBeforeQueuedSaveOrPreviewNeverFetchesOrPublishes() async throws {
    let model = PageCapturePresentation(attempt: try PageCapture(record: captureRecord())) { _, _ in
      Issue.record("Dismissed action reached transport")
      throw CancellationError()
    }
    let save = try #require(
      model.startSave(.html) { _ in Issue.record("Dismissed Save published") })
    model.cancel()
    await save.value
    #expect(!model.isLoading && !model.isSaving && model.file == nil)
    let preview = try #require(model.startPreview())
    model.cancel()
    await preview.value
    #expect(model.previewData == nil && model.error == nil && !model.isLoading)
  }

  @Test func cancelledCallerDoesNotDiscardAnAlreadyPreparedArtifact() async throws {
    let bytes = try capturePNGBytes()
    let model = PageCapturePresentation(attempt: try captureWithBytes(bytes, kind: "png")) { _, _ in
      try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    defer { model.cancel() }
    await model.prepare(.png, maximumBytes: PageCapture.previewLimit)
    let original = try #require(model.file)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await model.prepare(.png, maximumBytes: PageCapture.previewLimit)
    }
    await cancelled.value
    #expect(model.file === original)
    #expect(FileManager.default.fileExists(atPath: original.url.path))
    #expect(!model.isLoading)
  }

  @Test func pngDefaultUsesExistingPreviewAndKeepsOriginalBytesForSave() async throws {
    let bytes = try capturePNGBytes()
    let model = PageCapturePresentation(attempt: try captureWithBytes(bytes, kind: "png")) {
      key, limit in
      #expect(key.hasSuffix("/page.png"))
      #expect(limit == bytes.count)
      return try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    defer { model.cancel() }
    try #require(model.kind == .png)
    await model.prepare(model.kind, maximumBytes: PageCapture.previewLimit)
    let file = try #require(model.file)
    let preview = try await file.imagePreview()
    let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 2 && image.height == 1)
    #expect(try Data(contentsOf: file.url) == bytes)
    #expect(model.error == nil && model.unavailableReason == nil && !model.isLoading)
    // System destination and visible Save behavior are covered separately by
    // application-hosted acceptance; this test checks preview/original ownership.
  }

  @Test func failedPreparationCanRetryWithoutLosingTheAttempt() async throws {
    let bytes = try capturePNGBytes()
    let attempt = try captureWithBytes(bytes, kind: "png")
    let retry = CaptureRetryFixture(bytes: bytes)
    let model = PageCapturePresentation(attempt: attempt) { _, _ in try await retry.fetch() }
    defer { model.cancel() }
    await model.prepare(.png, maximumBytes: PageCapture.downloadLimit)
    #expect(model.error != nil)
    #expect(model.file == nil && !model.isLoading && model.unavailableReason == nil)
    #expect(model.attempt.canDownload(.png))
    await model.prepare(.png, maximumBytes: PageCapture.downloadLimit)
    let file = try #require(model.file)
    #expect(try Data(contentsOf: file.url) == bytes)
    #expect(model.error == nil && !model.isLoading)
    #expect(model.attempt.id == attempt.id && model.attempt.capturedAt == attempt.capturedAt)
  }

  @Test func previewRefusalCanPrepareOriginalWithExplicitDownloadBudget() async throws {
    let bytes = try capturePNGBytes()
    let model = PageCapturePresentation(attempt: try captureWithBytes(bytes, kind: "png")) {
      _, limit in
      #expect(limit == bytes.count)
      return try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    defer { model.cancel() }
    await model.prepare(.png, maximumBytes: 1)
    #expect(model.unavailableReason != nil && model.file == nil)
    #expect(model.error == nil && model.attempt.canDownload(.png))
    await model.prepare(.png, maximumBytes: PageCapture.downloadLimit)
    let file = try #require(model.file)
    #expect(try Data(contentsOf: file.url) == bytes)
    #expect(model.unavailableReason == nil && model.error == nil)
  }

  @Test func partialAttemptPreparationPreservesEarlierHistoryAndWarningCounts() async throws {
    let bytes = try capturePNGBytes()
    var row = try captureRecord()
    row["png_bytes"] = .number(Double(bytes.count))
    row["png_sha256"] = .string(
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    row["id"] = .string("attempt-a")
    let earlier = try PageCapture(record: row)
    let old = PageCapturePresentation(attempt: earlier) { _, _ in
      try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    await old.prepare(.png, maximumBytes: PageCapture.previewLimit)
    let oldFile = try #require(old.file)
    defer { old.cancel() }
    old.cancel()
    #expect(!FileManager.default.fileExists(atPath: oldFile.url.path))

    row["id"] = .string("attempt-b")
    row["captured_at"] = .string("2026-01-02T00:00:02.000Z")
    row["status"] = .string("partial")
    row["failure_code"] = .string("partial")
    row["failure_detail"] = .string(
      "Incomplete archive: 2 resource requests could not be saved; 1 section was still loading.")
    let current = PageCapturePresentation(attempt: try PageCapture(record: row)) { _, _ in
      try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
    }
    defer { current.cancel() }
    await current.prepare(.png, maximumBytes: PageCapture.previewLimit)
    #expect(current.file != nil && current.error == nil)
    #expect(current.attempt.warning?.missingResources == 2)
    #expect(current.attempt.warning?.unfinishedSections == 1)
    #expect(current.attempt.canDownload(.png) && current.attempt.canDownload(.html))
    #expect(old.attempt.id == "attempt-a" && old.attempt.status == .succeeded)
    #expect(old.attempt.capturedAt == "2026-01-01T00:00:02.000Z")
    #expect(old.attempt.warning == nil && old.file == nil)
    #expect(
      current.attempt.id == "attempt-b" && current.attempt.capturedAt == "2026-01-02T00:00:02.000Z")
  }

  @Test(arguments: ["failed", "blocked", "unsupported"])
  func terminalAttemptPresentationDoesNotFetchOrOfferArtifacts(status: String) async throws {
    var row = try captureRecord()
    row["status"] = .string(status)
    row["failure_code"] = .string("fixture_failure")
    row["failure_detail"] = .string("Synthetic terminal attempt")
    row["captured_at"] = .null
    for kind in ["html", "png"] {
      for field in ["key", "mime", "bytes", "sha256"] { row[kind + "_" + field] = .null }
    }
    let model = PageCapturePresentation(attempt: try PageCapture(record: row)) { _, _ in
      Issue.record("Terminal history must not fetch retained artifacts")
      throw CancellationError()
    }
    defer { model.cancel() }
    await model.prepare(.png, maximumBytes: PageCapture.previewLimit)
    #expect(model.file == nil && !model.isLoading && model.error == nil)
    #expect(model.unavailableReason != nil)
    #expect(!model.attempt.canDownload(.png) && !model.attempt.canDownload(.html))
    #expect(model.attempt.status.rawValue == status)
    #expect(model.attempt.failureDetail == "Synthetic terminal attempt")
  }

  @Test func previewRefusalKeepsExplicitDownloadAndOriginalAvailable() async throws {
    var row = try captureRecord()
    row["png_bytes"] = .number(128 * 1024 * 1024)
    let model = PageCapturePresentation(attempt: try PageCapture(record: row)) { _, _ in
      Issue.record("Preview budget must be checked before fetching")
      throw CancellationError()
    }
    #expect(model.kind == .png)
    await model.prepare(.png, maximumBytes: 8 * 1024 * 1024)
    #expect(model.file == nil)
    #expect(model.unavailableReason != nil)
    #expect(model.error == nil)
    #expect(model.attempt.canDownload(.png))
    #expect(model.attempt.sourceURL?.absoluteString == "https://example.test/article")
  }

  // Catches stale A publishing a file/error or clearing B's busy flag after cancellation.
  @Test(arguments: [false, true])
  func cancelledPreparationCannotReplaceNewerAttemptResult(firstFails: Bool) async throws {
    let data = Data("<p>retained</p>".utf8)
    let attempt = try captureWithBytes(data)
    let gate = CaptureFileGate()
    let model = PageCapturePresentation(attempt: attempt) { _, _ in try await gate.fetch() }
    let first = Task { await model.prepare(.html, maximumBytes: 1024) }
    await gate.waitForEntries(1)
    model.cancel()
    let second = Task { await model.prepare(.html, maximumBytes: 1024) }
    await gate.waitForEntries(2)
    let staleFile = try RetainedFile(data: data, contentType: "text/html", name: "page.html")
    if firstFails {
      staleFile.dispose()
      await gate.finish(0, result: .failure(CocoaError(.fileReadUnknown)))
    } else {
      await gate.finish(0, result: .success(staleFile))
    }
    await first.value
    #expect(model.isLoading)
    #expect(model.file == nil)
    #expect(model.error == nil)
    #expect(!FileManager.default.fileExists(atPath: staleFile.url.path))

    model.cancel()
    let lastFile = try RetainedFile(data: data, contentType: "text/html", name: "page.html")
    await gate.finish(1, result: .success(lastFile))
    await second.value
    #expect(!model.isLoading)
    #expect(model.file == nil)
    #expect(!FileManager.default.fileExists(atPath: lastFile.url.path))
  }

  @Test func successfulPreparationOwnsVerifiedBytesUntilDismissal() async throws {
    let data = Data("<p>retained</p>".utf8)
    let model = PageCapturePresentation(attempt: try captureWithBytes(data)) { _, _ in
      try RetainedFile(data: data, contentType: "text/html", name: "page.html")
    }
    await model.prepare(.html, maximumBytes: 1024)
    let file = try #require(model.file)
    #expect(try Data(contentsOf: file.url) == data)
    #expect(!model.isLoading)
    model.cancel()
    #expect(model.file == nil)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
  }
}

private actor CaptureRetryFixture {
  let bytes: Data
  private var failed = false
  init(bytes: Data) { self.bytes = bytes }
  func fetch() throws -> RetainedFile {
    if !failed {
      failed = true
      throw URLError(.notConnectedToInternet)
    }
    return try RetainedFile(data: bytes, contentType: "image/png", name: "page.png")
  }
}

private actor CaptureFileGate {
  private var entries: [CheckedContinuation<RetainedFile, Error>] = []
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

  func fetch() async throws -> RetainedFile {
    try await withCheckedThrowingContinuation { continuation in
      entries.append(continuation)
      for (count, observer) in observers where entries.count >= count { observer.resume() }
      observers.removeAll { entries.count >= $0.0 }
    }
  }

  func waitForEntries(_ count: Int) async {
    if entries.count >= count { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }

  func finish(_ index: Int, result: Result<RetainedFile, Error>) {
    entries[index].resume(with: result)
  }
}
