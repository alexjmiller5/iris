import Foundation
import Observation

struct RecordReference: Equatable {
  let table: String
  let id: String
}

struct ReferenceDestination {
  let table: String
  let row: WorkspaceRow
}

@Observable @MainActor
final class ReferenceNavigationModel {
  private(set) var confirmation: RecordReference?
  private(set) var error: String?
  private(set) var loading = false
  private let editor: RecordEditorModel
  private let read: (CoreView) async throws -> [WorkspaceRow]
  private let isCurrent: () -> Bool
  private let onOpen: (ReferenceDestination) -> Void
  private var revision = 0

  init(
    editor: RecordEditorModel, read: @escaping (CoreView) async throws -> [WorkspaceRow],
    isCurrent: @escaping () -> Bool = { true },
    onOpen: @escaping (ReferenceDestination) -> Void = { _ in }
  ) {
    self.editor = editor
    self.read = read
    self.isCurrent = isCurrent
    self.onOpen = onOpen
  }

  func open(table: String, id: String) async -> ReferenceDestination? {
    await resolve(RecordReference(table: table, id: id), discard: false)
  }

  func cancel() {
    revision += 1
    confirmation = nil
    error = nil
    loading = false
  }

  func discardAndOpen() async -> ReferenceDestination? {
    guard let confirmation else { return nil }
    return await resolve(confirmation, discard: true)
  }

  private func resolve(_ target: RecordReference, discard: Bool) async -> ReferenceDestination? {
    guard isCurrent(), !Task.isCancelled else { return nil }
    cancel()
    guard !editor.saving else {
      error = "Wait for the current save to finish before opening a related record."
      return nil
    }
    let request = revision
    let values = editor.draft.values
    let baseline = editor.draft.original
    loading = true
    defer { if request == revision { loading = false } }
    do {
      let rows = try await read(
        CoreView(
          table: target.table,
          filters: [CoreFilter(column: "id", op: .eq, value: .string(target.id))], limit: 1))
      guard request == revision, isCurrent(), !Task.isCancelled else { return nil }
      guard let row = rows.first(where: { $0.id == target.id }) else {
        throw WorkspaceError(
          message:
            "This record is not available locally. It may be missing, in the trash, or outside this replica.",
          violations: [])
      }
      guard !editor.saving else {
        throw WorkspaceError(
          message: "Wait for the current save to finish before opening a related record.",
          violations: [])
      }
      if discard {
        guard values == editor.draft.values, baseline == editor.draft.original else {
          throw WorkspaceError(
            message:
              "Your draft changed while opening the record. Your changes have been kept. Open it again to review.",
            violations: [])
        }
        try editor.discardDraft()
      } else if editor.dirty || editor.needsReview || editor.failure != nil {
        confirmation = target
        return nil
      }
      let destination = ReferenceDestination(table: target.table, row: row)
      // Journal removal and the guarded handoff share one MainActor turn.
      // Returning to an awaiting view before handing off would permit a context change.
      onOpen(destination)
      return destination
    } catch {
      guard request == revision, isCurrent(), !Task.isCancelled else { return nil }
      self.error = error.localizedDescription
      return nil
    }
  }
}
