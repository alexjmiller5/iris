import SwiftUI

/// Row actions, their column order and the Today boundary for the current view.
/// Filters and sorts live in the FilterBar, layout at the top of the Views sheet.
/// Changes apply immediately and save with the view when the Views sheet closes.
struct WorkspaceOptionsView: View {
  @Bindable var model: WorkspaceModel

  private var fields: [CatalogField] { model.viewFields }
  private var writable: [CatalogField] {
    fields.filter { field in
      !["id", "created_at", "updated_at", "hub_at", "deleted_at"].contains(field.id)
        && field.property["immutable"]?.isTrue != true
        && field.property["deprecated"]?.isTrue != true
        && field.property["derived_by"]?.text.nonempty == nil
    }
  }
  private var items: [CoreViewLayoutItem] {
    model.viewLayout ?? model.defaultViewLayout
  }
  private var dayStart: Binding<Date> {
    Binding(
      get: {
        Date(timeIntervalSinceReferenceDate: Double(model.viewDayStartMinutes) * 60)
      },
      set: { model.viewDayStartMinutes = Int($0.timeIntervalSinceReferenceDate / 60) % 1440 })
  }
  private var timeZoneProblem: String? {
    TimeZone(identifier: model.viewTimeZone) == nil ? "Enter a timezone such as Europe/Paris." : nil
  }

  var body: some View {
    Form {
      Section {
        TextField("Today timezone", text: $model.viewTimeZone)
          .accessibilityIdentifier("today-timezone")
        if let timeZoneProblem {
          Text(timeZoneProblem).font(.caption).foregroundStyle(.red)
        }
        DatePicker("Day starts at", selection: dayStart, displayedComponents: .hourAndMinute)
          .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
          .environment(\.calendar, Calendar(identifier: .gregorian))
          .accessibilityIdentifier("day-start-time")
      } header: {
        Text("Today")
      } footer: {
        Text("Filters set to Today use this timezone and day boundary.")
      }
      Section {
        ForEach($model.viewActions, id: \.id) { $action in
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
              let id = action.id
              model.viewLayout = items.filter { $0.kind != "action" || $0.id != id }
              model.viewActions.removeAll { $0.id == id }
            }
          }
        }
        Button("Add action") {
          guard let field = writable.first else { return }
          let id = UUID().uuidString
          model.viewLayout = items + [CoreViewLayoutItem(kind: "action", id: id)]
          model.viewActions.append(
            CoreRowAction(id: id, label: "New action", values: [field.id: .null]))
        }.disabled(model.viewActions.count >= 32 || writable.isEmpty)
      } header: {
        Text("Row actions")
      } footer: {
        Text("Each button applies its values to one record once the view is saved.")
      }
      if !model.viewActions.isEmpty {
        Section("Column and button order") {
          ForEach(items, id: \.self) { item in
            HStack {
              Text(
                item.kind == "action"
                  ? model.viewActions.first { $0.id == item.id }?.label ?? item.id
                  : fields.first { $0.id == item.id }?.label ?? item.id)
              Spacer()
              Button("Move up") { moveLayout(item, by: -1) }.disabled(items.first == item)
              Button("Move down") { moveLayout(item, by: 1) }.disabled(items.last == item)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Row actions and Today")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private func moveLayout(_ item: CoreViewLayoutItem, by delta: Int) {
    var next = items
    if let index = next.firstIndex(of: item), next.indices.contains(index + delta) {
      next.swapAt(index, index + delta)
      model.viewLayout = next
    }
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
