import SwiftUI

/// Its lifetime and identity belong to the panel, not to the record's draft.
struct IncomingReferencesView: View {
  let makeModel: @MainActor () -> IncomingReferencesModel?
  let canOpen: Bool
  let onOpenRecord: (String, String) -> Void
  @State private var model: IncomingReferencesModel?

  var body: some View {
    Section {
      if let model {
        if model.loading {
          ProgressView("Loading incoming references")
        } else if let error = model.error {
          Text(error).foregroundStyle(.red)
          Button("Retry incoming references") { Task { await model.refresh() } }
        } else if model.groups.isEmpty {
          Text("No reference fields point to this table.").foregroundStyle(.secondary)
        } else {
          ForEach(model.groups) { group in
            IncomingReferenceGroupView(
              group: group, model: model, canOpen: canOpen, onOpenRecord: onOpenRecord)
          }
        }
      } else {
        ProgressView("Loading incoming references")
      }
    } header: {
      Text("Incoming references")
    } footer: {
      Text("Records stored on this device that link to this record.")
    }
    .task {
      guard model?.isDisposed != false, let next = makeModel() else { return }
      // Reappearance gets fresh reads, while the disappearing section keeps
      // its previous rendered state until it is safely offscreen.
      model = next
      await next.refresh()
    }
    .onDisappear { model?.dispose() }
  }
}

private struct IncomingReferenceGroupView: View {
  let group: IncomingReferenceGroup
  let model: IncomingReferencesModel
  let canOpen: Bool
  let onOpenRecord: (String, String) -> Void
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      if group.source.incomplete {
        Text("Some records may be missing on this device.").foregroundStyle(.secondary)
      }
      ForEach(group.rows, id: \.byteExactID) { row in
        Button {
          onOpenRecord(group.source.table, row.id)
        } label: {
          Label(row.label, systemImage: "arrow.up.forward")
        }
        .accessibilityLabel("Open \(row.label)")
        .disabled(!canOpen)
      }
      if let reason = group.viewUnavailable {
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
      if group.loading {
        ProgressView("Loading records")
      } else if let error = group.error {
        Text(error).foregroundStyle(.red)
        Button("Retry records") { Task { await model.load(group.id, more: group.loaded) } }
      } else if group.loaded && group.rows.isEmpty {
        Text("No stored records link here.").foregroundStyle(.secondary)
      } else if group.nextOffset != nil {
        Button("Load more records") { Task { await model.load(group.id, more: true) } }
          .accessibilityIdentifier("incoming-more-\(group.source.table)-\(group.source.column)")
      }
    } label: {
      Text("\(group.source.table) · \(group.source.label)")
    }
    .task(id: expanded ? ObjectIdentifier(model) : nil) {
      if expanded { await model.load(group.id) }
    }
  }
}
