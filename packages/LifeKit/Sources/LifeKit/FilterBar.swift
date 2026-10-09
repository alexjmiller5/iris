import SwiftUI

/// The control a chip or header menu asks the bar to open.
enum FilterBarTarget: Hashable {
  case filter(UUID)
  case group(UUID)
}

/// Notion-style view controls above the records: Filter and Sort popovers and a
/// chip row. Edits apply immediately; closing a control saves the current view.
struct FilterBar: View {
  @Bindable var model: WorkspaceModel
  @Binding var editing: FilterBarTarget?
  let disabled: Bool
  @State private var adding = false
  @State private var sorting = false

  private var fields: [CatalogField] { model.viewFields }
  /// Flag quick filters that are off; an applied one shows as its ordinary chip.
  private var flagSuggestions: [CatalogField] {
    CatalogField.flagFilters(fields).map(\.flag).filter { !model.flagIsOn($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button {
          adding = true
        } label: {
          Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("filter-bar-filter")
        .accessibilityHint("Adds a filter to this view")
        .popover(isPresented: $adding, arrowEdge: .top) {
          AddFilterPopover(model: model).compactPopover()
        }
        Button {
          sorting = true
        } label: {
          Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("filter-bar-sort")
        .accessibilityValue(
          model.sortRules.isEmpty ? "None" : "\(model.sortRules.count) sorts")
        .popover(isPresented: $sorting, arrowEdge: .top) {
          SortMenu(model: model).compactPopover()
        }
        Spacer(minLength: 0)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      if !model.filters.isEmpty || !model.filterGroups.isEmpty || !model.sortRules.isEmpty
        || !flagSuggestions.isEmpty
      {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            if !model.sortRules.isEmpty { sortChip }
            ForEach(Array(model.filters.enumerated()), id: \.element.id) { index, filter in
              filterChip(filter, index: index)
            }
            ForEach(Array(model.filterGroups.enumerated()), id: \.element.id) { index, group in
              groupChip(group, index: index)
            }
            ForEach(flagSuggestions) { flag in
              Button {
                model.toggleFlag(flag.id)
                model.scheduleViewSave()
              } label: {
                Label(flag.label, systemImage: "flag")
              }
              .buttonStyle(.bordered).controlSize(.small).tint(.secondary)
              .accessibilityHint("Shows only records with this flag, with its reason")
              .accessibilityIdentifier("flag-chip-\(flag.id)")
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active filters and sorts")
      }
      if let error = model.viewSaveError {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
          .accessibilityIdentifier("view-save-error")
      }
    }
    .padding(.horizontal).padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(disabled)
    .onChange(of: adding) { if !adding { model.scheduleViewSave() } }
    .onChange(of: sorting) { if !sorting { model.scheduleViewSave() } }
    .onChange(of: editing) { if editing == nil { model.scheduleViewSave() } }
  }

  private func presented(_ target: FilterBarTarget) -> Binding<Bool> {
    Binding(get: { editing == target }, set: { if !$0, editing == target { editing = nil } })
  }

  private var sortChip: some View {
    let first = model.sortRules[0]
    let label = fields.first { $0.id == first.column }?.label ?? first.column
    let more = model.sortRules.count > 1 ? " +\(model.sortRules.count - 1)" : ""
    return Button {
      sorting = true
    } label: {
      Label(
        label + more, systemImage: first.direction == .asc ? "arrow.up" : "arrow.down")
    }
    .buttonStyle(.bordered).controlSize(.small).tint(.accentColor)
    .accessibilityLabel(
      "Sorted by \(label), \(first.direction == .asc ? "ascending" : "descending")"
        + (more.isEmpty ? "" : ", and \(model.sortRules.count - 1) more"))
    .accessibilityHint("Edits the sort order")
    .accessibilityIdentifier("sort-chip")
  }

  private func filterChip(_ filter: WorkspaceFilter, index: Int) -> some View {
    let field = fields.first { $0.id == filter.column }
    let active = filter.activeCoreFilter(field: field) != nil
    let summary = filter.summary(label: field?.label ?? filter.column)
    return Chip(
      title: summary, active: active, removeLabel: "Remove filter \(field?.label ?? filter.column)",
      identifier: "filter-chip-\(index)"
    ) {
      editing = .filter(filter.id)
    } remove: {
      if editing == .filter(filter.id) { editing = nil }
      model.removeFilter(filter.id)
      model.scheduleViewSave()
    }
    .accessibilityValue(active ? "Active" : "No value yet")
    .popover(isPresented: presented(.filter(filter.id)), arrowEdge: .top) {
      NavigationStack {
        FilterEditor(model: model, filter: filterBinding(filter.id), fields: fields)
      }
      .compactPopover()
    }
  }

  private func groupChip(_ group: WorkspaceFilterGroup, index: Int) -> some View {
    let count = group.filters.count
    let title = "\(group.match == "all" ? "All" : "Any") of \(count) \(count == 1 ? "rule" : "rules")"
    return Chip(
      title: title, active: group.activeCore(fields: fields) != nil,
      removeLabel: "Remove filter group", identifier: "group-chip-\(index)"
    ) {
      editing = .group(group.id)
    } remove: {
      if editing == .group(group.id) { editing = nil }
      model.removeFilterGroup(group.id)
      model.scheduleViewSave()
    }
    .popover(isPresented: presented(.group(group.id)), arrowEdge: .top) {
      NavigationStack {
        FilterGroupEditor(model: model, id: group.id, fields: fields)
      }
      .compactPopover()
    }
  }

  private func filterBinding(_ id: UUID) -> Binding<WorkspaceFilter>? {
    guard model.filters.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { model.filters.first { $0.id == id } ?? WorkspaceFilter(column: "") },
      set: { value in
        if let index = model.filters.firstIndex(where: { $0.id == id }) {
          model.filters[index] = value
        }
      })
  }
}

private struct Chip: View {
  let title: String
  let active: Bool
  let removeLabel: String
  let identifier: String
  let edit: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Button(action: edit) {
        Text(title).lineLimit(1).foregroundStyle(active ? Color.primary : Color.secondary)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(title)
      .accessibilityHint("Edits this filter")
      .accessibilityIdentifier(identifier)
      Button(action: remove) {
        Image(systemName: "xmark").imageScale(.small).foregroundStyle(.secondary)
          .frame(minWidth: 24, minHeight: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(removeLabel)
      .accessibilityIdentifier("remove-" + identifier)
    }
    .font(.callout)
    .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 2)
    .background(
      Capsule().fill(active ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1)))
  }
}

/// Filter button contents: a searchable property list. Choosing a property adds
/// its chip and opens the value editor in place.
private struct AddFilterPopover: View {
  let model: WorkspaceModel
  @State private var path: [FilterBarTarget] = []

  var body: some View {
    NavigationStack(path: $path) {
      PropertyPicker(fields: model.viewFields, title: "Filter by") { field in
        path.append(.filter(model.addFilter(column: field.id)))
      } footer: {
        NavigationLink {
          PropertyPicker(fields: model.viewFields, title: "First rule") { field in
            path.append(.group(model.addFilterGroup(column: field.id)))
          } footer: {
            EmptyView()
          }
        } label: {
          Label("Add filter group", systemImage: "rectangle.stack.badge.plus")
        }
        .accessibilityIdentifier("add-filter-group")
      }
      .navigationDestination(for: FilterBarTarget.self) { target in
        switch target {
        case .filter(let id):
          FilterEditor(
            model: model,
            filter: model.filters.contains { $0.id == id }
              ? Binding(
                get: { model.filters.first { $0.id == id } ?? WorkspaceFilter(column: "") },
                set: { value in
                  if let index = model.filters.firstIndex(where: { $0.id == id }) {
                    model.filters[index] = value
                  }
                }) : nil,
            fields: model.viewFields)
        case .group(let id):
          FilterGroupEditor(model: model, id: id, fields: model.viewFields)
        }
      }
    }
  }
}

struct PropertyPicker<Footer: View>: View {
  let fields: [CatalogField]
  let title: String
  let choose: (CatalogField) -> Void
  @ViewBuilder let footer: () -> Footer
  @State private var query = ""

  private var matches: [CatalogField] {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty
      ? fields : fields.filter { $0.label.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    List {
      Section {
        TextField("Search properties", text: $query)
          .accessibilityIdentifier("filter-property-search")
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
      }
      Section {
        ForEach(matches) { field in
          Button {
            choose(field)
          } label: {
            Label(field.label, systemImage: field.symbol)
              .foregroundStyle(.primary)
          }
          .tint(.primary)
          .accessibilityIdentifier("filter-property-\(field.id)")
        }
        if matches.isEmpty { Text("No matching properties").foregroundStyle(.secondary) }
      }
      Section { footer() }
    }
    .navigationTitle(title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Operator and value for one rule, by property type. Every change applies at once.
struct FilterEditor: View {
  let model: WorkspaceModel
  let filter: Binding<WorkspaceFilter>?
  let fields: [CatalogField]
  var onRemove: (() -> Void)? = nil
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    if let filter {
      FilterRuleForm(
        model: model, filter: filter, fields: fields,
        remove: {
          if let onRemove {
            onRemove()
          } else {
            model.removeFilter(filter.wrappedValue.id)
          }
          dismiss()
        })
    } else {
      Text("This filter was removed.").foregroundStyle(.secondary).padding()
    }
  }
}

private struct FilterRuleForm: View {
  let model: WorkspaceModel
  @Binding var filter: WorkspaceFilter
  let fields: [CatalogField]
  let remove: () -> Void
  @State private var dynamicOptions: [String] = []

  private var field: CatalogField? { fields.first { $0.id == filter.column } }
  private var type: String { field?.type ?? "text" }
  private var isDate: Bool { ["date", "datetime", "date_or_datetime"].contains(type) }
  private var needsValue: Bool { filter.operation != .empty && filter.operation != .notEmpty }

  var body: some View {
    Form {
      Section {
        Picker("Condition", selection: $filter.operation) {
          ForEach(WorkspaceFilter.operations(for: type), id: \.self) { Text($0.label).tag($0) }
        }
        .accessibilityIdentifier("filter-operation")
        if needsValue, isDate {
          Toggle("Today", isOn: $filter.today).accessibilityIdentifier("filter-today")
        }
      }
      if needsValue && !filter.today { Section("Value") { value } }
      Section {
        Button("Remove filter", role: .destructive, action: remove)
          .accessibilityIdentifier("remove-filter")
      }
    }
    .formStyle(.grouped)
    .navigationTitle(field?.label ?? filter.column)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onChange(of: filter.operation) {
      if !WorkspaceFilter.operations(for: type).contains(filter.operation) { filter.value = "" }
    }
    .task(id: filter.column) {
      guard ["select", "multi_select"].contains(type), let table = model.table,
        let workspace = model.client
      else { return }
      dynamicOptions = (try? await workspace.options(table: table, column: filter.column)) ?? []
    }
  }

  @ViewBuilder private var value: some View {
    if ["select", "multi_select"].contains(type) {
      let choices = uniqueChoices
      ForEach(choices, id: \.self) { choice in
        Button {
          filter.value = Data(filter.value.utf8) == Data(choice.utf8) ? "" : choice
        } label: {
          HStack {
            Text(choice).foregroundStyle(.primary)
            Spacer()
            if Data(filter.value.utf8) == Data(choice.utf8) {
              Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
          Data(filter.value.utf8) == Data(choice.utf8) ? .isSelected : [])
        .accessibilityIdentifier("filter-option-\(choice)")
      }
      if choices.isEmpty { Text("No options").foregroundStyle(.secondary) }
    } else if type == "bool" {
      Picker("Value", selection: $filter.value) {
        Text("True").tag("true")
        Text("False").tag("false")
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("filter-bool")
    } else if ["ref", "multi_ref"].contains(type), let field, let workspace = model.client {
      ReferenceField(field: referenceField(field), value: $filter.value, workspace: workspace)
        .id(filter.column)
    } else if isDate {
      DatePicker("Date", selection: dateBinding, displayedComponents: .date)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .accessibilityIdentifier("filter-date")
      if filter.value.isEmpty {
        Text("Choose a date to apply this filter.").font(.caption).foregroundStyle(.secondary)
      }
    } else {
      TextField("Value", text: $filter.value)
        .accessibilityIdentifier("filter-value")
        #if os(iOS)
          .keyboardType(["int", "number"].contains(type) ? .decimalPad : .default)
          .textInputAutocapitalization(.never)
        #endif
    }
  }

  private var uniqueChoices: [String] {
    var seen = Set<Data>()
    return ((field?.options ?? []) + dynamicOptions + [filter.value]).filter {
      !$0.isEmpty && seen.insert(Data($0.utf8)).inserted
    }
  }

  private var dateBinding: Binding<Date> {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return Binding(
      get: { formatter.date(from: String(filter.value.prefix(10))) ?? Date() },
      set: { filter.value = formatter.string(from: $0) })
  }

  private func referenceField(_ field: CatalogField) -> CatalogField {
    var property = field.property
    property["type"] = .string("ref")
    return CatalogField(property: property)
  }
}

/// An all/any group: its rules are edited in place like top-level filters.
struct FilterGroupEditor: View {
  @Bindable var model: WorkspaceModel
  let id: UUID
  let fields: [CatalogField]
  @Environment(\.dismiss) private var dismiss

  private var index: Int? { model.filterGroups.firstIndex { $0.id == id } }

  var body: some View {
    if let index {
      Form {
        Section {
          Picker("Match", selection: $model.filterGroups[index].match) {
            Text("All rules").tag("all")
            Text("Any rule").tag("any")
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("group-match")
        } footer: {
          Text("Records must match this group and every other filter.")
        }
        Section("Rules") {
          ForEach(model.filterGroups[index].filters) { rule in
            NavigationLink {
              FilterEditor(
                model: model, filter: ruleBinding(rule.id), fields: fields,
                onRemove: { removeRule(rule.id) })
            } label: {
              let field = fields.first { $0.id == rule.column }
              Text(rule.summary(label: field?.label ?? rule.column))
                .foregroundStyle(rule.activeCoreFilter(field: field) == nil ? .secondary : .primary)
            }
          }
          Menu {
            ForEach(fields) { field in
              Button(field.label) {
                model.filterGroups[index].filters.append(
                  WorkspaceFilter(
                    column: field.id, operation: WorkspaceFilter.operations(for: field.type)[0]))
              }
            }
          } label: {
            Label("Add rule", systemImage: "plus")
          }
          .disabled(model.filterGroups[index].filters.count >= 64)
          .accessibilityIdentifier("group-add-rule")
        }
        Section {
          Button("Remove group", role: .destructive) {
            model.removeFilterGroup(id)
            dismiss()
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Filter group")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
    } else {
      Text("This group was removed.").foregroundStyle(.secondary).padding()
    }
  }

  private func ruleBinding(_ rule: UUID) -> Binding<WorkspaceFilter>? {
    guard let group = index, model.filterGroups[group].filters.contains(where: { $0.id == rule })
    else { return nil }
    return Binding(
      get: {
        model.filterGroups.first { $0.id == id }?.filters.first { $0.id == rule }
          ?? WorkspaceFilter(column: "")
      },
      set: { value in
        guard let group = model.filterGroups.firstIndex(where: { $0.id == id }),
          let item = model.filterGroups[group].filters.firstIndex(where: { $0.id == rule })
        else { return }
        model.filterGroups[group].filters[item] = value
      })
  }

  private func removeRule(_ rule: UUID) {
    guard let group = model.filterGroups.firstIndex(where: { $0.id == id }) else { return }
    model.filterGroups[group].filters.removeAll { $0.id == rule }
  }
}

extension WorkspaceFilter {
  /// Short chip text, e.g. "Status: Draft" or "Due ≤ Today".
  func summary(label: String) -> String {
    let shown = today ? "Today" : value
    switch operation {
    case .empty: return "\(label) is empty"
    case .notEmpty: return "\(label) is not empty"
    case _ where shown.isEmpty: return label
    case .eq: return "\(label): \(shown)"
    case .ne: return "\(label): not \(shown)"
    case .contains: return "\(label) contains \(shown)"
    case .gt: return "\(label) > \(shown)"
    case .gte: return "\(label) ≥ \(shown)"
    case .lt: return "\(label) < \(shown)"
    case .lte: return "\(label) ≤ \(shown)"
    }
  }
}

extension CatalogField {
  var symbol: String {
    switch type {
    case "select", "multi_select": "list.bullet"
    case "int", "number": "number"
    case "bool": "checkmark.square"
    case "date", "datetime", "date_or_datetime": "calendar"
    case "ref", "multi_ref": "arrow.up.right"
    default: "textformat"
    }
  }
}

extension View {
  /// Popovers stay popovers on iPhone and get a sensible size on the Mac.
  func compactPopover() -> some View {
    #if os(iOS)
      self.frame(minWidth: 320, idealWidth: 360, minHeight: 360, idealHeight: 480)
        .presentationCompactAdaptation(.popover)
    #else
      self.frame(width: 340, height: 420)
    #endif
  }
}
