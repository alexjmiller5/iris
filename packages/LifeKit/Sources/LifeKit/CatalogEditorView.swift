import SwiftUI

struct CatalogEditorView: View {
  @Bindable var model: CatalogEditorModel
  @Environment(\.dismiss) private var dismiss
  @State private var pending: (() -> Void)?
  @State private var discarding = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Catalog") {
          Picker(
            "Section",
            selection: Binding(
              get: { model.mode },
              set: { mode in
                change { model.select(nil, mode: mode) }
              })
          ) {
            ForEach(CatalogEditorModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          Picker(
            "Entry",
            selection: Binding(
              get: { model.original?["id"]?.text ?? "" },
              set: { id in
                change { model.select(model.entries.first { $0["id"]?.text == id }) }
              })
          ) {
            Text("Add new").tag("")
            ForEach(model.entries, id: \.self) { row in
              Text(row[model.mode == .property ? "col" : "text"]?.text ?? row["id"]?.text ?? "")
                .tag(row["id"]?.text ?? "")
            }
          }
          TextField(model.mode == .property ? "Column ID" : "Rule ID", text: $model.key)
            .disabled(model.original != nil).accessibilityIdentifier("catalog-key")
        }
        if model.mode == .property { propertyFields } else { ruleFields }
        if let failure = model.failure {
          Section {
            Text(failure).foregroundStyle(.red).textSelection(.enabled)
              .accessibilityIdentifier("catalog-error")
          }
        }
        if let receipt = model.receipt {
          Section { Text(receipt).accessibilityIdentifier("catalog-receipt") }
        }
        Section {
          Text(
            "Changes affect catalog guidance and validation. Existing record values are not rewritten. Enforced rules require verified sync coverage before record editing."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .accessibilityIdentifier("catalog-form")
      .disabled(model.saving)
      .navigationTitle("Edit catalog")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { change { dismiss() } }.disabled(model.saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }
            .disabled(model.saving || !model.dirty).accessibilityIdentifier("catalog-save")
        }
      }
      .confirmationDialog("Discard unsaved catalog changes?", isPresented: $discarding) {
        Button("Discard changes", role: .destructive) {
          let action = pending
          pending = nil
          action?()
        }
        Button("Keep editing", role: .cancel) { pending = nil }
      }
    }
    .interactiveDismissDisabled(model.dirty || model.saving)
    #if os(macOS)
      .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 700)
    #endif
  }

  private var propertyFields: some View {
    Group {
      Section("Property") {
        TextField("Label", text: text("label")).accessibilityIdentifier("catalog-label")
        Picker("Type", selection: text("type")) {
          ForEach(CatalogEditorModel.types, id: \.self) { Text($0).tag($0) }
        }
        TextField("Description", text: text("description"), axis: .vertical)
          .accessibilityIdentifier("catalog-description")
        Toggle("Required", isOn: flag("required"))
        Toggle("Immutable after creation", isOn: flag("immutable"))
        Toggle("Deprecated", isOn: flag("deprecated"))
        Toggle(
          "Has default",
          isOn: Binding(
            get: {
              model.fields["default_value"] != nil && model.fields["default_value"] != .null
            }, set: { model.fields["default_value"] = $0 ? .string("") : .null }))
        if model.fields["default_value"] != nil && model.fields["default_value"] != .null {
          TextField("Default value", text: text("default_value"))
        }
        TextField("Validation pattern", text: text("pattern")).accessibilityIdentifier(
          "catalog-pattern")
        if ["ref", "multi_ref"].contains(model.fields["type"]?.text ?? "") {
          TextField("Referenced table", text: text("ref_table"))
        }
        if let provider = model.fields["derived_by"]?.text, !provider.isEmpty {
          LabeledContent("Derived provider", value: provider)
        }
      }
      if ["select", "multi_select"].contains(model.fields["type"]?.text ?? "") {
        Section("Options") {
          ForEach($model.options) { $option in
            HStack(alignment: .top) {
              VStack {
                TextField("Value", text: $option.value)
                TextField("Description", text: $option.description, axis: .vertical)
              }
              Button("Remove", role: .destructive) {
                model.options.removeAll { $0.id == option.id }
              }
            }
          }
          Button("Add option") { model.options.append(.init(value: "", description: "")) }
          TextField("Options query", text: text("options_sql"), axis: .vertical)
        }
      }
    }
  }

  private var ruleFields: some View {
    Section("Rule") {
      Picker("Kind", selection: text("kind")) {
        ForEach(["doctrine", "audit", "invariant"], id: \.self) { Text($0).tag($0) }
      }
      Picker("Scope", selection: text("scope")) {
        Text("Table").tag("table")
        Text("Estate").tag("estate")
      }
      TextField("Column (optional)", text: text("col"))
      TextField("Rule guidance", text: text("text"), axis: .vertical)
        .accessibilityIdentifier("catalog-rule-text")
      TextField("SQL", text: text("sql"), axis: .vertical).font(.system(.body, design: .monospaced))
      Toggle("Enforce on record writes", isOn: flag("enforce"))
    }
  }

  private func text(_ key: String) -> Binding<String> {
    Binding(get: { model.fields[key]?.text ?? "" }, set: { model.fields[key] = .string($0) })
  }
  private func flag(_ key: String) -> Binding<Bool> {
    Binding(
      get: { model.fields[key] == .number(1) || model.fields[key] == .bool(true) },
      set: { model.fields[key] = .number($0 ? 1 : 0) })
  }
  private func change(_ action: @escaping () -> Void) {
    if model.dirty {
      pending = action
      discarding = true
    } else {
      action()
    }
  }
}
