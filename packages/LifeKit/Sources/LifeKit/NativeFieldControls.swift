import SwiftUI

@MainActor
struct NativeChoiceField: View {
  let field: CatalogField
  let isNew: Bool
  let focus: FocusState<String?>.Binding
  @Binding var value: String
  @State private var model: NativeChoiceModel
  @State private var customValue = ""

  init(
    field: CatalogField, isNew: Bool, value: Binding<String>, workspace: NativeWorkspace?,
    focus: FocusState<String?>.Binding, isCurrent: @escaping () -> Bool,
    choiceModel: NativeChoiceModel? = nil
  ) {
    self.field = field
    self.isNew = isNew
    self.focus = focus
    _value = value
    _model = State(
      initialValue: choiceModel
        ?? NativeChoiceModel(
          load: {
            guard let workspace, let table = field.property["tbl"]?.text.nonempty else {
              if field.property["options_sql"]?.text.nonempty != nil {
                throw WorkspaceError(
                  message: "Choices are unavailable. Your value has been kept.", violations: [])
              }
              return field.options
            }
            return try await workspace.options(table: table, column: field.id)
          }, isCurrent: isCurrent))
  }

  private var freeValues: Bool {
    field.options.isEmpty && field.property["options_sql"]?.text.nonempty == nil
  }

  var body: some View {
    Group {
      VStack(alignment: .leading, spacing: 10) {
        if let projected = try? NativeChoiceOptions(
          field: field, dynamic: model.options, value: value)
        {
          if field.type == "multi_select" {
            multipleChoices(projected)
          } else if freeValues {
            TextField(field.label, text: $value, axis: .vertical)
              .fixedSize(horizontal: false, vertical: true)
              .focused(focus, equals: field.id)
              .accessibilityIdentifier("field-\(field.id)")
          } else {
            Picker(
              field.label,
              selection: Binding(
                get: { Data(value.utf8) },
                set: { id in
                  if id.isEmpty {
                    value = ""
                  } else if let option = projected.choices.first(where: { $0.id == id }) {
                    choose(option.value)
                  }
                })
            ) {
              Text(
                isNew
                  ? field.property["default_value"]?.text.nonempty.map { "Default: \($0)" }
                    ?? "Not set" : "Not set"
              )
              .tag(Data())
              ForEach(projected.choices.filter { !$0.value.isEmpty }) { option in
                Text(label(option)).tag(option.id)
              }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("field-\(field.id)")
          }
        } else {
          Text("This value is not a list of text choices. Edit the JSON source to repair it.")
            .foregroundStyle(.red)
        }
      }
      .task(id: field.property["options_sql"]?.text) { await model.refresh() }
      .onDisappear { model.cancel() }
      if model.loading { ProgressView("Loading choices") }
      if let error = model.error {
        Text(error).font(.caption).foregroundStyle(.red)
        Button("Retry choices") { Task { await model.refresh() } }
          .disabled(model.loading)
      }
      if field.type == "multi_select" {
        DisclosureGroup("Edit JSON source") {
          TextEditor(text: $value)
            .font(.system(.body, design: .monospaced)).frame(minHeight: 100)
            .focused(focus, equals: field.id)
            .accessibilityLabel(field.label + " JSON source")
            .accessibilityIdentifier("field-\(field.id)-source")
        }
      } else if !freeValues {
        DisclosureGroup("Enter a value") {
          TextField(field.label, text: $value, axis: .vertical)
            .fixedSize(horizontal: false, vertical: true)
            .focused(focus, equals: field.id)
            .accessibilityIdentifier("field-\(field.id)-source")
        }
      }
    }
  }

  private func multipleChoices(_ projected: NativeChoiceOptions) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      let selected = projected.choices.filter { projected.selection.contains($0.value) }
      if selected.isEmpty {
        Text("No choices selected").foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(selected) { option in
              Button {
                guard var selection = try? ReferenceSelection(value: value, multiple: true) else {
                  return
                }
                selection.remove(option.value)
                value = selection.value
                focus.wrappedValue = nil
              } label: {
                Label(option.value.isEmpty ? "Empty value" : option.value, systemImage: "xmark")
              }
              .buttonStyle(.bordered)
              .accessibilityLabel("Remove \(label(option))")
              .accessibilityIdentifier("remove-choice-\(field.id)-\(option.value)")
              .help(option.description ?? "Remove this choice")
            }
          }
        }
      }
      let available = projected.choices.filter { !projected.selection.contains($0.value) }
      if !available.isEmpty {
        Menu("Add choice") {
          ForEach(available) { option in
            Button(label(option)) { choose(option.value) }
          }
        }.accessibilityIdentifier("add-choice-\(field.id)")
      }
      if freeValues {
        HStack {
          TextField("New choice", text: $customValue)
            .focused(focus, equals: field.id + ".new")
            .onSubmit { addCustomValue() }
          Button("Add", action: addCustomValue)
            .disabled(customValue.isEmpty || projected.selection.contains(customValue))
        }
      }
    }
  }

  private func label(_ option: NativeChoiceOption) -> String {
    let name = option.value.isEmpty ? "Empty value" : option.value
    return option.description.map { name + " - " + $0 } ?? name
  }

  private func choose(_ option: String) {
    guard
      var selection = try? ReferenceSelection(value: value, multiple: field.type == "multi_select")
    else { return }
    selection.choose(option)
    value = selection.value
    focus.wrappedValue = nil
  }

  private func addCustomValue() {
    guard !customValue.isEmpty,
      let selection = try? ReferenceSelection(value: value, multiple: true),
      !selection.contains(customValue)
    else { return }
    choose(customValue)
    customValue = ""
  }
}

struct NativeDateField: View {
  let field: CatalogField
  let kind: NativeDateKind
  let focus: FocusState<String?>.Binding
  @Binding var value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let date = NativeDateValue.parse(value, kind: kind) {
        DatePicker(
          field.label,
          selection: Binding(
            get: { date }, set: { value = NativeDateValue.format($0, kind: kind) }),
          displayedComponents: kind == .date ? [.date] : [.date, .hourAndMinute]
        )
        .environment(\.calendar, Calendar(identifier: .gregorian))
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .accessibilityIdentifier("date-picker-\(field.id)")
      } else {
        if !value.isEmpty {
          Text("This value cannot be shown in the date picker. The source has been kept.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button(kind == .date ? "Use today" : "Use current time") {
          value = NativeDateValue.currentValue(at: Date(), kind: kind)
          focus.wrappedValue = nil
        }.accessibilityIdentifier("choose-date-\(field.id)")
      }
      DisclosureGroup {
        TextField(field.label, text: $value)
          .focused(focus, equals: field.id)
          .autocorrectionDisabled()
          .accessibilityIdentifier("field-\(field.id)")
        if kind == .datetime { Text("UTC").font(.caption).foregroundStyle(.secondary) }
        if !value.isEmpty {
          Button("Clear date") {
            value = ""
            focus.wrappedValue = nil
          }.accessibilityIdentifier("clear-date-\(field.id)")
        }
      } label: {
        Text("Date source").accessibilityIdentifier("date-source-\(field.id)")
      }
    }
  }
}

struct NativeLinkField: View {
  let field: CatalogField
  let focus: FocusState<String?>.Binding
  @Binding var value: String
  @Environment(\.openURL) private var openURL
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField(field.label, text: $value, axis: .vertical)
          .fixedSize(horizontal: false, vertical: true)
          .focused(focus, equals: field.id)
          .autocorrectionDisabled()
          .accessibilityIdentifier("field-\(field.id)")
        if let url = NativeFieldLink.destination(type: field.type, value: value) {
          Button {
            focus.wrappedValue = nil
            openURL(url) { accepted in failed = !accepted }
          } label: {
            Label(
              field.type == "email"
                ? "Compose email" : field.type == "phone" ? "Call" : "Open website",
              systemImage: "arrow.up.right.square"
            ).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
          }.accessibilityIdentifier("open-link-\(field.id)")
        }
      }
      if failed { Text("No app could open this link.").font(.caption).foregroundStyle(.red) }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onChange(of: value) { failed = false }
  }
}
