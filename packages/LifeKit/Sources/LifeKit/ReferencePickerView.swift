import SwiftUI

struct ReferenceField: View {
  let field: CatalogField
  @Binding var value: String
  @State private var picker: ReferencePickerModel?
  let onOpen: () -> Void
  let canEdit: Bool
  let canOpen: Bool
  let availability: String?
  let onOpenRecord: ((String, String) -> Void)?

  init(
    field: CatalogField, value: Binding<String>, workspace: NativeWorkspace,
    onOpen: @escaping () -> Void = {}, canEdit: Bool = true,
    canOpen: Bool = true, availability: String? = nil,
    onOpenRecord: ((String, String) -> Void)? = nil
  ) {
    self.field = field
    _value = value
    self.onOpen = onOpen
    self.canEdit = canEdit
    self.canOpen = canOpen
    self.availability = availability
    self.onOpenRecord = onOpenRecord
    _picker = State(
      initialValue: try? ReferencePickerModel(
        table: field.property["ref_table"]?.text ?? "", value: value.wrappedValue,
        multiple: field.type == "multi_ref", load: { try await workspace.rows(view: $0) }))
  }

  var body: some View {
    if let picker {
      VStack(alignment: .leading, spacing: 10) {
        if canEdit {
          NavigationLink {
            ReferencePickerView(field: field, model: picker, value: $value)
              .onAppear(perform: onOpen)
          } label: {
            Text(
              picker.selection.ids.isEmpty
                ? "Choose \(field.type == "multi_ref" ? "records" : "a record")"
                : picker.selection.ids.map { picker.label(for: $0) }.joined(separator: ", "))
          }
          .accessibilityIdentifier("field-\(field.id)")
        }
        if let onOpenRecord {
          ForEach(picker.selection.ids, id: \.self) { id in
            Button {
              onOpen()
              onOpenRecord(picker.table, id)
            } label: {
              Label(picker.label(for: id), systemImage: "arrow.up.right")
            }
            .buttonStyle(.borderless)
            .disabled(!canOpen)
            .accessibilityLabel("Open \(picker.label(for: id))")
            .accessibilityIdentifier("open-reference-\(field.id)-\(id)")
          }
          if let availability { Text(availability).font(.caption).foregroundStyle(.secondary) }
          if picker.selection.ids.contains(where: { picker.label(for: $0) == "Unavailable" }) {
            Text("Unavailable references are kept. Open a record to check its local availability.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if !canEdit && picker.selection.ids.isEmpty {
          Text("No related records").foregroundStyle(.secondary)
        }
      }
      .task { await picker.resolveSelected() }
    } else {
      Text("This reference value cannot be read. The original value has been preserved.")
        .foregroundStyle(.secondary)
    }
  }
}

private struct ReferencePickerView: View {
  let field: CatalogField
  @Bindable var model: ReferencePickerModel
  @Binding var value: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      if !model.selection.ids.isEmpty {
        Section("Selected") {
          ForEach(Array(model.selection.ids.enumerated()), id: \.offset) { _, id in
            HStack {
              Text(model.label(for: id))
              Spacer()
              Button {
                model.remove(id)
                value = model.selection.value
              } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Remove \(model.label(for: id))")
            }
          }
          if model.selection.ids.contains(where: { model.label(for: $0) == "Unavailable" }) {
            Text("Unavailable records remain selected until you remove them.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section("Records") {
        ForEach(model.rows) { row in
          Button {
            model.choose(row)
            value = model.selection.value
            if !model.selection.multiple { dismiss() }
          } label: {
            HStack {
              Text(row.label).foregroundStyle(.primary)
              Spacer()
              if model.selection.ids.contains(row.id) { Image(systemName: "checkmark") }
            }.contentShape(.rect)
          }
          .accessibilityAddTraits(model.selection.ids.contains(row.id) ? [.isSelected] : [])
        }
        if model.rows.isEmpty && !model.loading {
          Text("No matching records").foregroundStyle(.secondary)
        }
        if model.canLoadMore {
          Button("Load more") { Task { await model.reload(more: true) } }.disabled(model.loading)
        }
        if model.loading { ProgressView() }
        if let error = model.error { Text(error).foregroundStyle(.red) }
      }
    }
    .navigationTitle(field.label)
    .searchable(text: $model.search, prompt: "Search records")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }
    .task(id: model.search) { await model.reload() }
    .task { await model.resolveSelected() }
    .onDisappear { model.invalidateSearch() }
  }
}
