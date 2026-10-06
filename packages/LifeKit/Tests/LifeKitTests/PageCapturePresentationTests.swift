import Foundation
import Testing

@testable import LifeKit

@MainActor
struct PageCapturePresentationTests {
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
