import SwiftUI

struct PropertyLayoutView: View {
  let model: WorkspaceModel
  private let context: WorkspaceEditingContext?
  private let generation: Int
  @Environment(\.dismiss) private var dismiss
  @State private var fields: [CatalogField]
  @State private var selected: Set<String>
  @State private var useDefault: Bool
  @State private var error: String?

  init(model: WorkspaceModel) {
    self.model = model
    context = model.editingContext
    generation = model.workspaceGeneration
    let fields = model.orderedRecordFields(model.properties.map(CatalogField.init))
      .filter { $0.id != model.titleProperty?.id }
    _fields = State(initialValue: fields)
    _selected = State(initialValue: Set(model.visibleRecordColumns ?? fields.map(\.id)))
    _useDefault = State(initialValue: model.visibleRecordColumns == nil)
  }

  var body: some View {
    List {
      Section {
        if let title = model.titleProperty {
          LabeledContent("Title", value: title.label)
        }
        Button("Show all properties") {
          fields = model.properties.map(CatalogField.init)
            .filter { $0.id != model.titleProperty?.id }
          selected = Set(fields.map(\.id))
          useDefault = true
        }.accessibilityIdentifier("properties-show-all")
        Button("Title only") {
          selected = []
          useDefault = false
        }.accessibilityIdentifier("properties-title-only")
      } footer: {
        Text(
          "The title stays visible. Reorder properties and choose which to show. Hidden values are kept in More properties when you open a record."
        )
      }
      Section("Properties") {
        ForEach(fields) { field in
          Toggle(
            field.label,
            isOn: Binding(
              get: { selected.contains(field.id) },
              set: { visible in
                if visible { selected.insert(field.id) } else { selected.remove(field.id) }
                useDefault = false
              }
            )
          )
          .accessibilityIdentifier("property-visible-\(field.id)")
          .contextMenu {
            Button("Move up") { move(field.id, by: -1) }
              .disabled(fields.first?.id == field.id)
            Button("Move down") { move(field.id, by: 1) }
              .disabled(fields.last?.id == field.id)
          }
          .accessibilityAction(named: "Move up") { move(field.id, by: -1) }
          .accessibilityAction(named: "Move down") { move(field.id, by: 1) }
        }
        .onMove { source, destination in
          fields.move(fromOffsets: source, toOffset: destination)
          useDefault = false
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
    }
    .accessibilityIdentifier("property-layout")
    #if os(iOS)
      .environment(\.editMode, .constant(.active))
    #endif
    .navigationTitle("Properties")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Apply") {
          do {
            guard generation == model.workspaceGeneration else { throw CancellationError() }
            try model.applyPropertyLayout(
              columns: useDefault ? nil : fields.filter { selected.contains($0.id) }.map(\.id),
              context: context)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.accessibilityIdentifier("apply-property-layout")
      }
    }
  }

  private func move(_ id: String, by offset: Int) {
    guard let index = fields.firstIndex(where: { $0.id == id }),
      fields.indices.contains(index + offset)
    else { return }
    fields.swapAt(index, index + offset)
    useDefault = false
  }
}
