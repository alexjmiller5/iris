import CryptoKit
import Foundation

enum PageCaptureError: Error, Equatable, LocalizedError {
  case invalidMetadata
  case previewUnavailable
  case artifactUnavailable
  case integrityMismatch

  var errorDescription: String? {
    switch self {
    case .invalidMetadata: "Capture metadata is missing or invalid."
    case .previewUnavailable:
      "This artifact exceeds the viewing limit. The retained capture is unchanged."
    case .artifactUnavailable: "This attempt has no retained artifact."
    case .integrityMismatch: "The downloaded artifact does not match its capture metadata."
    }
  }
}

/// An explicit host-selected observation, never inferred from a personal table or file prefix.
/// Authorization remains the host/server's responsibility on every file request.
struct PageCapture: Sendable {
  enum Kind: String, CaseIterable, Sendable { case png, html }
  enum Status: String, Sendable { case succeeded, partial, failed, blocked, unsupported }
  struct Artifact: Sendable {
    let key: String
    let mime: String
    let bytes: Int
    let sha256: String
  }
  struct Warning: Sendable {
    let message: String
    let missingResources: Int
    let unfinishedSections: Int

    init(_ message: String) throws {
      let prefix = "Incomplete archive: "
      guard message.hasPrefix(prefix), message.hasSuffix(".") else {
        throw PageCaptureError.invalidMetadata
      }
      let clauses = String(message.dropFirst(prefix.count).dropLast()).components(separatedBy: "; ")
      var resources = 0
      var sections = 0
      guard (1...2).contains(clauses.count) else { throw PageCaptureError.invalidMetadata }
      for (index, clause) in clauses.enumerated() {
        let words = clause.split(separator: " ", omittingEmptySubsequences: false)
        guard let first = words.first, let count = Int(first), count > 0,
          String(count) == first
        else { throw PageCaptureError.invalidMetadata }
        if clause == "\(count) resource requests could not be saved", index == 0 {
          resources = count
        } else if clause
          == (count == 1 ? "1 section was still loading" : "\(count) sections were still loading"),
          index == clauses.count - 1
        {
          sections = count
        } else {
          throw PageCaptureError.invalidMetadata
        }
      }
      self.message = message
      missingResources = resources
      unfinishedSections = sections
    }
  }

  static let downloadLimit = 128 * 1024 * 1024
  static let previewLimit = 8 * 1024 * 1024
  let id: String
  let captureID: String
  let eventID: String
  let subscriptionID: String
  let sourceTable: String
  let sourceRowID: String
  let sourceColumn: String
  /// Optional external-navigation action; originalURL remains historical source text.
  let sourceURL: URL?
  let originalURL: String
  let observedSourceRevision: String
  let attemptedAt: String
  let capturedAt: String?
  let status: Status
  let warning: Warning?
  let failureCode: String?
  let failureDetail: String?
  private let artifacts: [Kind: Artifact]

  init(record: WorkspaceRecord) throws {
    func text(_ field: String) throws -> String {
      guard case .string(let value) = record[field], !value.isEmpty else {
        throw PageCaptureError.invalidMetadata
      }
      return value
    }
    func timestamp(_ field: String) throws -> String {
      let value = try text(field)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      guard value.hasSuffix("Z"),
        fractional.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
      else { throw PageCaptureError.invalidMetadata }
      return value
    }
    id = try text("id")
    captureID = try text("capture_id")
    eventID = try text("event_id")
    subscriptionID = try text("subscription_id")
    sourceTable = try text("source_table")
    sourceRowID = try text("source_row_id")
    sourceColumn = try text("source_column")
    originalURL = try text("source_url")
    // Reuse host website-link policy, with the external viewer's credential refusal.
    // An unavailable Open original action must never discard an unsupported attempt.
    if !originalURL.contains(where: { $0.isWhitespace || $0 == "\\" }),
      let url = NativeFieldLink.destination(type: "url", value: originalURL),
      url.user == nil, url.password == nil
    {
      sourceURL = url
    } else {
      sourceURL = nil
    }
    observedSourceRevision = try text("observed_source_revision")
    guard
      (try? JSONDecoder().decode(WorkspaceRecord.self, from: Data(observedSourceRevision.utf8)))
        != nil
    else { throw PageCaptureError.invalidMetadata }
    attemptedAt = try timestamp("attempted_at")
    guard let outcome = Status(rawValue: try text("status")) else {
      throw PageCaptureError.invalidMetadata
    }
    status = outcome
    switch outcome {
    case .succeeded, .partial:
      capturedAt = try timestamp("captured_at")
      if outcome == .partial {
        guard record["failure_code"] == .string("partial") else {
          throw PageCaptureError.invalidMetadata
        }
        let detail = try text("failure_detail")
        warning = try Warning(detail)
        failureCode = "partial"
        failureDetail = detail
      } else {
        guard record["failure_code"] == .null, record["failure_detail"] == .null else {
          throw PageCaptureError.invalidMetadata
        }
        warning = nil
        failureCode = nil
        failureDetail = nil
      }
      var files: [Kind: Artifact] = [:]
      for kind in Kind.allCases {
        let prefix = kind.rawValue
        let key = try text(prefix + "_key")
        do { _ = try retainedFileRoute(key: key) } catch { throw PageCaptureError.invalidMetadata }
        let mime = try text(prefix + "_mime")
        let digest = try text(prefix + "_sha256")
        guard mime == (kind == .png ? "image/png" : "text/html"),
          digest.utf8.count == 64,
          digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
          case .number(let bytes) = record[prefix + "_bytes"], bytes.isFinite,
          bytes > 0, bytes <= 250 * 1024 * 1024, bytes.rounded() == bytes
        else { throw PageCaptureError.invalidMetadata }
        files[kind] = Artifact(key: key, mime: mime, bytes: Int(bytes), sha256: digest)
      }
      artifacts = files
    case .failed, .blocked, .unsupported:
      guard record["captured_at"] == .null else { throw PageCaptureError.invalidMetadata }
      for kind in Kind.allCases {
        for field in ["key", "mime", "bytes", "sha256"] {
          guard record[kind.rawValue + "_" + field] == .null else {
            throw PageCaptureError.invalidMetadata
          }
        }
      }
      failureCode = try text("failure_code")
      switch record["failure_detail"] {
      case .null: failureDetail = nil
      case .string(let detail): failureDetail = detail
      default: throw PageCaptureError.invalidMetadata
      }
      capturedAt = nil
      artifacts = [:]
      warning = nil
    }
  }

  func artifact(_ kind: Kind) throws -> Artifact {
    guard let artifact = artifacts[kind] else { throw PageCaptureError.artifactUnavailable }
    return artifact
  }

  func canDownload(_ kind: Kind) -> Bool {
    artifacts[kind].map { $0.bytes <= Self.downloadLimit } ?? false
  }

  /// The resolver is the existing enrolled host's authenticated retainedFile closure.
  /// It must neither bypass server file authorization nor return a previously authorized cache.
  func loadArtifact(
    _ kind: Kind, maximumBytes: Int,
    fetch: @Sendable (String, Int) async throws -> RetainedFile
  ) async throws -> RetainedFile {
    try Task.checkCancellation()
    let expected = try artifact(kind)
    guard maximumBytes > 0, expected.bytes <= min(maximumBytes, Self.downloadLimit) else {
      throw PageCaptureError.previewUnavailable
    }
    let file = try await fetch(expected.key, expected.bytes)
    do {
      try Task.checkCancellation()
      guard file.contentType == expected.mime else { throw PageCaptureError.integrityMismatch }
      let verification = Task.detached(priority: .utility) {
        let input = try FileHandle(forReadingFrom: file.url)
        defer { try? input.close() }
        var digest = SHA256()
        var count = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
          try Task.checkCancellation()
          count += chunk.count
          guard count <= expected.bytes else { throw PageCaptureError.integrityMismatch }
          digest.update(data: chunk)
        }
        guard count == expected.bytes,
          digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256
        else { throw PageCaptureError.integrityMismatch }
      }
      try await withTaskCancellationHandler {
        try await verification.value
      } onCancel: {
        verification.cancel()
      }
      try Task.checkCancellation()
      return file
    } catch {
      file.dispose()
      throw error
    }
  }
}
