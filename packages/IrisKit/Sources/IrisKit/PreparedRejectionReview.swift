import Foundation

/// A persisted review ready for the host's guarded sheet-to-editor handoff.
@MainActor
struct PreparedRejectionReview {
  let resolved: NativeResolvedDestination
  let context: WorkspaceEditingContext
  let editor: RecordEditorModel
  let generation: Int
  let sourceQuery: [Data]
}
