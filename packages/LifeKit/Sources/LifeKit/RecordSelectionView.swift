import SwiftUI

struct RecordSelectionView: View {
  let snapshot: RecordExportSnapshot
  let rows: [WorkspaceRow]
  let workspace: NativeWorkspace
  let writable: Bool
  let isCurrent: () -> Bool
  let prepare: ([String]) throws -> BulkRecordModel
  @Environment(\.dismiss) private var dismiss
  @State private var selection = Set<Data>()
  @State private var column = Data()
  @State private var value = ""
  @State private var clear = false
  @State private var batch: BulkRecordModel?
  @State private var error: String?
  @State private var export: SelectedExport?
  @FocusState private var focus: String?

  private var fields: [CatalogField] {
    RecordDraft(properties: snapshot.properties, original: [:]).fields
  }
  private var field: CatalogField? { fields.first { Data($0.id.utf8) == column } ?? fields.first }
  private var ids: [String] { rows.filter { selection.contains($0.byteExactID) }.map(\.id) }
  private var running: Bool { batch?.running == true }
  private var canChange: Bool { writable && isCurrent() && !running && !ids.isEmpty }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button(selection.count == rows.count ? "Clear selection" : "Select loaded rows") {
            selection = selection.count == rows.count ? [] : Set(rows.map(\.byteExactID))
          }.disabled(running).accessibilityIdentifier("bulk-select-all")
          ForEach(rows, id: \.byteExactID) { row in
            Toggle(
              isOn: Binding(
                get: { selection.contains(row.byteExactID) },
                set: {
                  if $0 {
                    selection.insert(row.byteExactID)
                  } else {
                    selection.remove(row.byteExactID)
                  }
                }
              )
            ) {
              Text(row.label).lineLimit(2)
            }.disabled(running).accessibilityIdentifier("bulk-row-" + row.id)
          }
        } header: {
          Text("\(ids.count) selected of \(rows.count) loaded rows")
        }
        if writable {
          Section {
            if let field {
              Picker(
                "Property",
                selection: Binding(
                  get: { Data(field.id.utf8) },
                  set: {
                    column = $0
                    value = ""
                    clear = false
                  }
                )
              ) {
                // The supplied catalog and this list are immutable for the sheet lifetime.
                ForEach(fields.indices, id: \.self) { index in
                  Text(fields[index].label).tag(Data(fields[index].id.utf8))
                }
              }.accessibilityIdentifier("bulk-property")
              Toggle("Clear value (null)", isOn: $clear).accessibilityIdentifier("bulk-clear")
              if !clear { propertyInput(field).id(Data(field.id.utf8)) }
              Button("Apply to selected") {
                var draft = RecordDraft(properties: [field.property], original: nil)
                draft.setValue(clear ? "" : value, for: field.id, preservingEmptyString: !clear)
                apply(draft.patch)
              }.disabled(!canChange).accessibilityIdentifier("bulk-apply")
            }
            Button("Move selected to trash", role: .destructive) {
              apply([
                "deleted_at": .string(Date().ISO8601Format(.init(includingFractionalSeconds: true)))
              ])
            }.disabled(!canChange).accessibilityIdentifier("bulk-trash")
          } footer: {
            Text(
              "Each row is saved separately. A rejected row does not stop the remaining selection.")
          }
          .disabled(running || !isCurrent())
        }
        if let batch {
          Section {
            Text(
              "\(batch.results.filter { $0.status == .succeeded }.count) succeeded, \(batch.results.filter { $0.status == .failed }.count) failed, \(batch.results.filter { $0.status == .unattempted }.count) unattempted"
            )
            .accessibilityIdentifier("bulk-result-summary")
            if running {
              ProgressView("Saving selected rows")
              Button("Cancel remaining") { batch.cancelRemaining() }.accessibilityIdentifier(
                "bulk-cancel")
            }
            if let message = batch.error { Text(message).foregroundStyle(.red) }
            DisclosureGroup("Row results") {
              ForEach(batch.results) { result in
                VStack(alignment: .leading) {
                  Text(result.recordID).textSelection(.enabled)
                  Text(result.error ?? resultLabel(result.status)).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
        Section {
          Button("Export selection") { export = SelectedExport(ids: ids) }
            .disabled(ids.isEmpty || running).accessibilityIdentifier("bulk-export")
        } footer: {
          Text(
            "Exports use the stored rows captured when this sheet opened. Table completeness and freshness are unknown."
          )
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Selected rows")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            batch?.cancelRemaining()
            dismiss()
          }.accessibilityIdentifier("bulk-done")
        }
      }
      .sheet(item: $export) { target in
        RecordExportView(snapshot: snapshot, selectedIDs: target.ids)
      }
    }
    #if os(macOS)
      .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 640)
    #endif
    .onDisappear { batch?.cancelRemaining() }
  }

  @ViewBuilder private func propertyInput(_ field: CatalogField) -> some View {
    if ["ref", "multi_ref"].contains(field.type) {
      ReferenceField(field: field, value: $value, workspace: workspace, canOpen: false)
    } else if ["select", "multi_select"].contains(field.type) {
      NativeChoiceField(
        field: field, isNew: false, value: $value, workspace: workspace, focus: $focus,
        isCurrent: isCurrent)
    } else if field.type == "bool" {
      Picker("Value", selection: $value) {
        Text("Choose a value").tag("")
        Text("True").tag("true")
        Text("False").tag("false")
      }
    } else {
      TextField("Value", text: $value, axis: .vertical).accessibilityIdentifier("bulk-value")
    }
  }
  private func apply(_ patch: WorkspaceRecord) {
    guard canChange else { return }
    do {
      let operation = try prepare(ids)
      batch = operation
      error = nil
      operation.start(values: patch)
    } catch { self.error = error.localizedDescription }
  }
  private func resultLabel(_ status: BulkRecordResult.Status) -> String {
    switch status {
    case .succeeded: "Saved locally"
    case .failed: "Failed"
    case .unattempted: "Not attempted"
    }
  }
}

private struct SelectedExport: Identifiable {
  let id = UUID()
  let ids: [String]
}
