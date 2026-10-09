import SwiftUI

/// List content for the workspace Issues section. The owner refreshes and disposes
/// the model and prepares a durable review draft before changing navigation.
struct RejectionInboxView: View {
  let model: RejectionInboxModel
  let isBusy: Bool
  let onReview: (CoreRejectedEdit) -> Void

  var body: some View {
    Group {
      VStack(alignment: .leading, spacing: 6) {
        if let total = model.total {
          Text("\(total) rejected edits · \(model.entries.count) loaded")
            .accessibilityIdentifier("rejected-edit-count")
        } else {
          Text("Rejected edits")
        }
        Text(
          "Review a record and save your correction. Edits stay here until the hub accepts them."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.entries, id: \.inboxID) { entry in
        RejectedEditRow(entry: entry, canReview: !isBusy && !model.loading) {
          onReview(entry)
        }
      }
      if let error = model.error {
        VStack(alignment: .leading, spacing: 6) {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("Retry rejected edits") {
            Task {
              if model.total == nil { await model.refresh() } else { await model.loadMore() }
            }
          }
          .disabled(model.loading || isBusy)
          .accessibilityIdentifier("retry-rejected-edits")
        }
      } else if model.total == 0 && model.entries.isEmpty && !model.loading {
        Text("No rejected edits.").foregroundStyle(.secondary)
      } else if model.total != nil && model.nextOffset != nil {
        Button("Load more rejected edits") { Task { await model.loadMore() } }
          .disabled(model.loading || isBusy)
          .accessibilityIdentifier("load-more-rejected-edits")
      }
      if model.loading { ProgressView("Loading rejected edits…") }
    }
  }
}

private struct RejectedEditRow: View {
  let entry: CoreRejectedEdit
  let canReview: Bool
  let onReview: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.table).font(.headline)
      Text(entry.rowID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Text(entry.errors.map { JSONValue.object($0).text }.joined(separator: "\n"))
        .font(.caption).textSelection(.enabled)
      DisclosureGroup("Submitted values") {
        Text(JSONValue.object(entry.submitted).text)
          .font(.caption.monospaced()).textSelection(.enabled)
      }
      Button("Review edit", action: onReview)
        .disabled(!canReview)
        .accessibilityLabel("Review edit in \(entry.table), record \(entry.rowID)")
        .accessibilityIdentifier("review-rejected-edit")
    }
  }
}
