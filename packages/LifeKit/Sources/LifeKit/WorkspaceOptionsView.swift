import SwiftUI

private struct EditableSort: Identifiable {
  let id = UUID()
  var value: CoreSort
}

struct WorkspaceOptionsView: View {
  let model: WorkspaceModel
  let context: WorkspaceEditingContext?
  let fields: [CatalogField]
  @Environment(\.dismiss) private var dismiss
  @State private var sorts: [EditableSort]
  @State private var filters: [WorkspaceFilter]
  @State private var groups: [WorkspaceFilterGroup]
  @State private var actions: [CoreRowAction]
  @State private var layout: [CoreViewLayoutItem]?
  @State private var timeZone: String
  @State private var dayStart: Date
  @State private var error: String?

  init(model: WorkspaceModel) {
    self.model = model
    context = model.editingContext
    fields = model.viewFields
    _sorts = State(initialValue: model.sortRules.map { EditableSort(value: $0) })
    _filters = State(initialValue: model.filters)
    _groups = State(initialValue: model.filterGroups)
    _actions = State(initialValue: model.viewActions)
    _layout = State(initialValue: model.viewLayout)
    _timeZone = State(initialValue: model.viewTimeZone)
    _dayStart = State(
      initialValue: Date(timeIntervalSinceReferenceDate: Double(model.viewDayStartMinutes) * 60))
  }

  private var writable: [CatalogField] {
    fields.filter { field in
      !["id", "created_at", "updated_at", "hub_at", "deleted_at"].contains(field.id)
        && field.property["immutable"]?.isTrue != true
        && field.property["deprecated"]?.isTrue != true
        && field.property["derived_by"]?.text.nonempty == nil
    }
  }
  private var items: [CoreViewLayoutItem] {
    layout ?? model.defaultViewLayout
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Sort order") {
          ForEach($sorts) { $sort in
            VStack(alignment: .leading) {
              Picker("Sort by", selection: $sort.value.column) {
                ForEach(fields) { Text($0.label).tag($0.id) }
              }.accessibilityIdentifier("sort-column")
                .onChange(of: sort.value.column) { sort.value.mode = nil }
              Picker("Direction", selection: $sort.value.direction) {
                Text("Ascending").tag(CoreSortDirection.asc)
                Text("Descending").tag(CoreSortDirection.desc)
              }.accessibilityIdentifier("sort-direction")
              if ["select", "multi_select"].contains(
                fields.first { $0.id == sort.value.column }?.type ?? "")
              {
                Picker(
                  "Compare",
                  selection: Binding(
                    get: { sort.value.mode ?? .value }, set: { sort.value.mode = $0 })
                ) {
                  Text("Value order").tag(CoreSortMode.value)
                  Text("Option order").tag(CoreSortMode.options)
                }
              }
              HStack {
                Button("Move up") { moveSort(sort.id) }.disabled(sorts.first?.id == sort.id)
                Button("Remove sort", role: .destructive) { sorts.removeAll { $0.id == sort.id } }
              }
            }
          }
          Button("Add sort") {
            if let field = fields.first(where: { f in !sorts.contains { $0.value.column == f.id } })
            {
              sorts.append(EditableSort(value: CoreSort(column: field.id, direction: .asc)))
            }
          }.disabled(sorts.count >= 16)
        }
        Section("Match all filters") {
          ForEach($filters) { $filter in
            WorkflowFilterRow(filter: $filter, fields: fields, workspace: context?.workspace) {
              filters.removeAll { $0.id == filter.id }
            }
          }
          Button("Add filter") {
            if let first = fields.first {
              filters.append(WorkspaceFilter(column: first.id, operation: .empty))
            }
          }
        }
        Section {
          ForEach($groups) { $group in
            VStack(alignment: .leading, spacing: 12) {
              Picker("Match", selection: $group.match) {
                Text("All rules").tag("all")
                Text("Any rule").tag("any")
              }
              ForEach($group.filters) { $filter in
                WorkflowFilterRow(filter: $filter, fields: fields, workspace: context?.workspace) {
                  group.filters.removeAll { $0.id == filter.id }
                }
              }
              Button("Add rule") {
                if let first = fields.first {
                  group.filters.append(WorkspaceFilter(column: first.id, operation: .empty))
                }
              }.disabled(group.filters.count >= 64)
              Button("Remove group", role: .destructive) { groups.removeAll { $0.id == group.id } }
            }
          }
          Button("Add filter group") {
            if let first = fields.first {
              groups.append(
                WorkspaceFilterGroup(filters: [WorkspaceFilter(column: first.id, operation: .empty)]
                ))
            }
          }.disabled(groups.count >= 16)
          TextField("Today timezone", text: $timeZone)
          DatePicker("Day starts at", selection: $dayStart, displayedComponents: .hourAndMinute)
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .accessibilityIdentifier("day-start-time")
        } header: {
          Text("Filter groups")
        } footer: {
          Text(
            "Records must match every group and the individual filters. Today starts at this time in the selected timezone."
          )
        }
        Section {
          ForEach($actions, id: \.id) { $action in
            VStack(alignment: .leading, spacing: 12) {
              TextField("Button label", text: $action.label)
              ForEach(action.values.keys.sorted(), id: \.self) { column in
                if let field = writable.first(where: { $0.id == column }) {
                  WorkflowActionValue(
                    field: field,
                    value: Binding(
                      get: { action.values[column] ?? .null }, set: { action.values[column] = $0 }))
                } else {
                  Text("Unavailable property: \(column)").foregroundStyle(.red)
                }
                Button("Remove value", role: .destructive) {
                  action.values.removeValue(forKey: column)
                }
              }
              Menu("Add property value") {
                ForEach(writable.filter { action.values[$0.id] == nil }) { field in
                  Button(field.label) { action.values[field.id] = .null }
                }
              }
              Button("Remove action", role: .destructive) {
                layout = items.filter { $0.kind != "action" || $0.id != action.id }
                actions.removeAll { $0.id == action.id }
              }
            }
          }
          Button("Add action") {
            guard let field = writable.first else { return }
            let id = UUID().uuidString
            layout = items + [CoreViewLayoutItem(kind: "action", id: id)]
            actions.append(CoreRowAction(id: id, label: "New action", values: [field.id: .null]))
          }.disabled(actions.count >= 32 || writable.isEmpty)
        } header: {
          Text("Row actions")
        } footer: {
          Text(
            "Save the view to use its buttons. Each button applies the saved values to one record.")
        }
        if !actions.isEmpty {
          Section("Column and button order") {
            ForEach(items, id: \.self) { item in
              HStack {
                Text(
                  item.kind == "action"
                    ? actions.first { $0.id == item.id }?.label ?? item.id
                    : fields.first { $0.id == item.id }?.label ?? item.id)
                Spacer()
                Button("Move up") { moveLayout(item, by: -1) }.disabled(items.first == item)
                Button("Move down") { moveLayout(item, by: 1) }.disabled(items.last == item)
              }
            }
          }
        }
        Section {
          Button("Reset sort and filters") {
            sorts = []
            filters = []
            groups = []
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle("View options")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") {
            do {
              try model.applyWorkflowOptions(
                sorts: sorts.map(\.value), filters: filters, groups: groups, actions: actions,
                layout: layout, timeZone: timeZone,
                dayStartMinutes: Int(dayStart.timeIntervalSinceReferenceDate / 60), context: context
              )
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
  private func moveSort(_ id: UUID) {
    if let index = sorts.firstIndex(where: { $0.id == id }), index > 0 {
      sorts.swapAt(index, index - 1)
    }
  }
  private func moveLayout(_ item: CoreViewLayoutItem, by delta: Int) {
    var next = items
    if let index = next.firstIndex(of: item), next.indices.contains(index + delta) {
      next.swapAt(index, index + delta)
      layout = next
    }
  }
}

private struct WorkflowFilterRow: View {
  @Binding var filter: WorkspaceFilter
  let fields: [CatalogField]
  let workspace: NativeWorkspace?
  let remove: () -> Void
  private var field: CatalogField? { fields.first { $0.id == filter.column } }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Property", selection: $filter.column) {
        ForEach(fields) { Text($0.label).tag($0.id) }
      }
      .accessibilityIdentifier("filter-column")
      .onChange(of: filter.column) {
        filter.value = ""
        filter.today = false
        filter.operation = WorkspaceFilter.operations(for: field?.type ?? "text")[0]
      }
      Picker("Condition", selection: $filter.operation) {
        ForEach(WorkspaceFilter.operations(for: field?.type ?? "text"), id: \.self) {
          Text($0.label).tag($0)
        }
      }.accessibilityIdentifier("filter-operation")
      if filter.operation != .empty && filter.operation != .notEmpty {
        if ["date", "datetime"].contains(field?.type ?? "") {
          Toggle("Today", isOn: $filter.today)
        }
        if !filter.today {
          if let field, ["ref", "multi_ref"].contains(field.type), let workspace {
            ReferenceField(field: referenceField(field), value: $filter.value, workspace: workspace)
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
      }
      Button("Remove filter", role: .destructive, action: remove)
    }.padding(.vertical, 4)
  }
  private func referenceField(_ field: CatalogField) -> CatalogField {
    var property = field.property
    property["type"] = .string("ref")
    return CatalogField(property: property)
  }
}

private struct WorkflowActionValue: View {
  let field: CatalogField
  @Binding var value: JSONValue
  private var text: Binding<String> {
    Binding(
      get: { field.formValue(value) },
      set: { raw in
        if raw.isEmpty {
          value = .null
        } else if field.type == "bool" {
          value = .bool(raw == "true")
        } else if ["number", "int"].contains(field.type), let number = Double(raw), number.isFinite
        {
          value = .number(number)
        } else {
          value = .string(raw)
        }
      })
  }
  var body: some View {
    if field.type == "bool" {
      Picker(field.label, selection: text) {
        Text("Empty").tag("")
        Text("True").tag("true")
        Text("False").tag("false")
      }
    } else if field.type == "select", !field.options.isEmpty {
      Picker(field.label, selection: text) {
        Text("Empty").tag("")
        ForEach(
          Array(Set(field.options + [text.wrappedValue])).filter { !$0.isEmpty }.sorted(),
          id: \.self
        ) { Text($0).tag($0) }
      }
    } else {
      TextField(field.label, text: text, axis: .vertical)
    }
  }
}
