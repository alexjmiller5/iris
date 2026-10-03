import SwiftUI

struct WorkspaceOptionsView: View {
  let model: WorkspaceModel
  let context: WorkspaceEditingContext?
  let fields: [CatalogField]
  @Environment(\.dismiss) private var dismiss
  @State private var sortColumn: String
  @State private var ascending: Bool
  @State private var filters: [WorkspaceFilter]
  @State private var error: String?

  init(model: WorkspaceModel) {
    self.model = model
    context = model.editingContext
    fields = model.properties.map(CatalogField.init)
    _sortColumn = State(initialValue: model.sortColumn)
    _ascending = State(initialValue: model.sortAscending)
    _filters = State(initialValue: model.filters)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Sort") {
          Picker("Sort by", selection: $sortColumn) {
            Text("Default order").tag("")
            ForEach(fields) { Text($0.label).tag($0.id) }
          }.accessibilityIdentifier("sort-column")
          if !sortColumn.isEmpty {
            Picker("Direction", selection: $ascending) {
              Text("Ascending").tag(true)
              Text("Descending").tag(false)
            }.accessibilityIdentifier("sort-direction")
            if model.sortRules.count > 1 {
              Text(
                "Then "
                  + model.sortRules.dropFirst().map { rule in
                    (fields.first { $0.id == rule.column }?.label ?? rule.column)
                      + (rule.direction == .asc ? " ascending" : " descending")
                  }.joined(separator: ", ")
              ).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Section {
          ForEach($filters) { $filter in
            let field = fields.first(where: { $0.id == filter.column })
            VStack(alignment: .leading, spacing: 12) {
              Picker("Property", selection: $filter.column) {
                ForEach(fields) { Text($0.label).tag($0.id) }
              }.accessibilityIdentifier("filter-column")
                .onChange(of: filter.column) {
                  let operations = WorkspaceFilter.operations(
                    for: fields.first(where: { $0.id == filter.column })?.type ?? "text")
                  if !operations.contains(filter.operation) { filter.operation = operations[0] }
                  filter.value = ""
                }
              Picker("Condition", selection: $filter.operation) {
                ForEach(WorkspaceFilter.operations(for: field?.type ?? "text"), id: \.self) {
                  Text($0.label).tag($0)
                }
              }.accessibilityIdentifier("filter-operation")
              if filter.operation != .empty && filter.operation != .notEmpty {
                if let field, ["ref", "multi_ref"].contains(field.type),
                  let workspace = context?.workspace
                {
                  ReferenceField(
                    field: referenceField(field), value: $filter.value, workspace: workspace
                  )
                  .id(filter.column)
                } else if field?.type == "bool" {
                  Picker("Value", selection: $filter.value) {
                    Text("Choose a value").tag("")
                    Text("True").tag("true")
                    Text("False").tag("false")
                  }
                } else {
                  TextField("Value", text: $filter.value).accessibilityIdentifier("filter-value")
                }
              }
              Button("Remove filter", role: .destructive) {
                filters.removeAll { $0.id == filter.id }
              }
            }.padding(.vertical, 4)
          }
          Button("Add filter") {
            if let field = fields.first {
              filters.append(
                WorkspaceFilter(
                  column: field.id, operation: WorkspaceFilter.operations(for: field.type)[0]))
            }
          }.disabled(fields.isEmpty)
        } header: {
          Text("Filters")
        } footer: {
          Text("Records must match every filter. Search and trash selection still apply.")
        }
        Section {
          Button("Reset sort and filters") {
            sortColumn = ""
            ascending = true
            filters = []
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle("Sort and filter")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            do {
              try model.applyViewOptions(
                sortColumn: sortColumn, ascending: ascending, filters: filters, context: context)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }.accessibilityIdentifier("apply-view-options")
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 440, minHeight: 480)
    #endif
  }

  private func referenceField(_ field: CatalogField) -> CatalogField {
    var property = field.property
    // A contains filter matches one member, so its picker selects one reference.
    property["type"] = .string("ref")
    return CatalogField(property: property)
  }
}
