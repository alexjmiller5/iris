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
  var onChange: (String) -> Void = { _ in }
  var snapshot: (() async throws -> MarkdownDocument)?

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

  func fail(_ message: String) {
    ready = false
    failure = message
  }

  func invalidate() {
    active = false
    snapshot = nil
  }
}
