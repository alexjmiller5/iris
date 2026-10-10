import SwiftUI

/// Read-only presentation shares the editor's typed helpers and reference labels.
struct NativePropertyValue: View {
  let field: CatalogField
  let value: String
  let workspace: NativeWorkspace?
  let transport: HubTransport?
  var imageSize: CGFloat = 32

  var body: some View {
    let images = ImageReference.previews(type: field.type, value: value)
    Group {
      if !images.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 4) {
            ForEach(Array(images.prefix(8)), id: \.self) { image in
              NativeImagePreview(
                reference: image, label: field.label, transport: transport, size: imageSize)
            }
            if images.count > 8 { Text("+\(images.count - 8)").font(.caption) }
          }
        }
      } else if ["ref", "multi_ref"].contains(field.type) {
        ReferenceValue(field: field, value: value, workspace: workspace)
          .id(Self.referenceID(field: field, value: value, workspace: workspace))
      } else if field.type == "markdown" && !value.isEmpty {
        NativeMarkdownPreview(value: value)
      } else if field.isFlag, let on = Self.flagValue(value) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .accessibilityLabel(on ? "Yes" : "No")
      } else if let values = Self.choiceValues(type: field.type, value: value) {
        OptionChips(field: field, values: values)
      } else {
        Text(Self.text(type: field.type, value: value))
      }
    }
  }

  nonisolated static func text(type: String, value: String, locale: Locale = .current) -> String {
    guard !value.isEmpty else { return "Not set" }
    if type == "markdown" { return String(NativeMarkdownPreview.render(value).characters) }
    if ["ref", "multi_ref"].contains(type) { return "Unavailable" }
    if let kind = NativeDateKind(rawValue: type),
      let date = NativeDateValue.parse(value, kind: kind)
    {
      let format = Date.FormatStyle(
        date: .abbreviated, time: kind == .datetime ? .shortened : .omitted, locale: locale,
        timeZone: TimeZone(secondsFromGMT: 0)!)
      return date.formatted(format) + (kind == .datetime ? " UTC" : "")
    }
    if type == "bool", let on = flagValue(value) { return on ? "Yes" : "No" }
    if type == "json" { return jsonText(value) }
    if type == "multi_select",
      let values = try? JSONDecoder().decode([String].self, from: Data(value.utf8))
    {
      return values.isEmpty ? "Not set" : values.joined(separator: ", ")
    }
    return value
  }

  /// Stored flag source as true/false; empty and anything else is nil.
  nonisolated static func flagValue(_ value: String) -> Bool? {
    if ["true", "1", "1.0"].contains(value) { return true }
    if ["false", "0", "0.0"].contains(value) { return false }
    return nil
  }

  /// Select, multi-select and json lists of plain values as chips; nil keeps the text fallback.
  nonisolated static func choiceValues(type: String, value: String) -> [String]? {
    if type == "select" { return value.isEmpty ? nil : [value] }
    if type == "json" {
      guard
        case .array(let items)? = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)),
        !items.isEmpty, items.allSatisfy(\.isScalar)
      else { return nil }
      return items.map(\.text)
    }
    guard type == "multi_select",
      let values = try? JSONDecoder().decode([String].self, from: Data(value.utf8)),
      !values.isEmpty
    else { return nil }
    return values
  }

  /// Other json as readable text: objects as `key: value`, lists of records as a count.
  nonisolated static func jsonText(_ value: String) -> String {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) else {
      return value
    }
    switch json {
    case .array(let items) where items.isEmpty: return "Not set"
    case .array(let items) where items.allSatisfy(\.isScalar):
      return items.map(\.text).joined(separator: ", ")
    case .array(let items): return "\(items.count) \(items.count == 1 ? "item" : "items")"
    case .object(let fields):
      return fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text)" }
        .joined(separator: ", ")
    default: return json.text
    }
  }

  struct ReferenceID: Hashable {
    let fields: [Data]
    let workspace: ObjectIdentifier?
  }
  static func referenceID(field: CatalogField, value: String, workspace: NativeWorkspace?)
    -> ReferenceID
  {
    ReferenceID(
      fields: [
        field.property["tbl"]?.text ?? "", field.id, field.type,
        field.property["ref_table"]?.text ?? "", value,
      ].map { Data($0.utf8) }, workspace: workspace.map(ObjectIdentifier.init))
  }

  /// Live labels for one cell's references, read with the other cells rendered alongside.
  @MainActor static func referenceLabels(
    field: CatalogField, value: String, workspace: NativeWorkspace
  ) async -> String {
    guard !value.isEmpty else { return "Not set" }
    guard let table = field.property["ref_table"]?.text.nonempty,
      let selection = try? ReferenceSelection(value: value, multiple: field.type == "multi_ref")
    else { return "Unavailable" }
    guard !selection.ids.isEmpty else { return "Not set" }
    let labels =
      (try? await workspace.referenceLabels(
        selection.ids.map { CoreRecordTarget(table: table, id: $0) })) ?? []
    guard !Task.isCancelled else { return "Unavailable" }
    // Trashed and missing targets read as unavailable, as in the reference picker.
    return selection.ids.map { id in
      labels.first { Data($0.id.utf8) == Data(id.utf8) && !$0.trashed }?.label ?? "Unavailable"
    }.joined(separator: ", ")
  }

  private struct ReferenceValue: View {
    let field: CatalogField
    let value: String
    let workspace: NativeWorkspace?
    @State private var resolved: String?
    @State private var request: UUID?

    var body: some View {
      Text(resolved ?? (value.isEmpty ? "Not set" : workspace == nil ? "Unavailable" : "Loading…"))
        .task {
          let ticket = UUID()
          request = ticket
          guard let workspace else {
            resolved = value.isEmpty ? "Not set" : "Unavailable"
            return
          }
          let label = await NativePropertyValue.referenceLabels(
            field: field, value: value, workspace: workspace)
          guard request == ticket, !Task.isCancelled else { return }
          resolved = label
        }
        .onDisappear {
          request = nil
          resolved = nil
        }
    }
  }
}
