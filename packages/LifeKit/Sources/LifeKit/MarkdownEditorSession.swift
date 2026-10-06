import Foundation
import Observation

struct MarkdownDocument: Codable, Equatable, Sendable {
  let id: String
  var value: String
  let label: String
  let readOnly: Bool
}

@Observable @MainActor
final class MarkdownEditorSession {
  private(set) var document: MarkdownDocument
  var ready = false
  private(set) var failure: String?
  private var active = true
  private var changeRevision = 0
  var onChange: (String) -> Void = { _ in }
  var snapshot: ((Bool) async throws -> MarkdownDocument)?
  var resumeEditing: (() -> Void)?

  init(value: String, label: String, readOnly: Bool = false) {
    document = MarkdownDocument(
      id: UUID().uuidString, value: value, label: label, readOnly: readOnly)
  }

  func begin(value: String, label: String, readOnly: Bool) {
    document = MarkdownDocument(
      id: UUID().uuidString, value: value, label: label, readOnly: readOnly)
    active = true
    failure = nil
  }

  @discardableResult
  func receive(_ message: [String: Any]) -> Bool {
    guard active, message["type"] as? String == "change",
      message["id"] as? String == document.id, let value = message["value"] as? String,
      !document.readOnly
    else { return false }
    editSource(value)
    return true
  }

  func markReady() {
    guard active else { return }
    failure = nil
    ready = true
  }

  func editSource(_ value: String) {
    guard active, !document.readOnly else { return }
    changeRevision += 1
    document.value = value
    onChange(value)
  }

  func acceptSnapshot(_ snapshot: MarkdownDocument) throws {
    guard active, snapshot.id == document.id else {
      throw WorkspaceError(
        message: "The editor document changed. Your draft is still open.", violations: [])
    }
    editSource(snapshot.value)
  }

  func collectSnapshot(lock: Bool) async throws {
    guard let snapshot else {
      throw WorkspaceError(
        message: "The editor is unavailable. Your draft has been kept.", violations: [])
    }
    let revision = changeRevision
    let captured = try await snapshot(lock)
    guard active, captured.id == document.id else {
      throw WorkspaceError(
        message: "The editor document changed. Your draft has been kept.", violations: [])
    }
    // A nonlocking background read may return after a newer IPC change. Keep
    // that later native draft instead of replacing it with the older snapshot.
    if lock || revision == changeRevision || captured.value == document.value {
      try acceptSnapshot(captured)
    }
  }

  func fail(_ message: String) {
    ready = false
    failure = message
  }

  func invalidate() {
    active = false
    snapshot = nil
    resumeEditing = nil
  }
}
