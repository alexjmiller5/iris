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
    if type == "bool" {
      if ["true", "1", "1.0"].contains(value) { return "Yes" }
      if ["false", "0", "0.0"].contains(value) { return "No" }
    }
    if type == "multi_select",
      let values = try? JSONDecoder().decode([String].self, from: Data(value.utf8))
    {
      return values.isEmpty ? "Not set" : values.joined(separator: ", ")
    }
    return value
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

  @MainActor static func referenceLabels(
    field: CatalogField, value: String, load: @escaping (CoreView) async throws -> [WorkspaceRow]
  ) async -> String {
    guard !value.isEmpty else { return "Not set" }
    guard let table = field.property["ref_table"]?.text.nonempty,
      let model = try? ReferencePickerModel(
        table: table, value: value, multiple: field.type == "multi_ref", load: load)
    else { return "Unavailable" }
    guard !Task.isCancelled else { return "Unavailable" }
    await model.resolveSelected()
    guard !Task.isCancelled else { return "Unavailable" }
    return model.selection.ids.isEmpty
      ? "Not set" : model.selection.ids.map { model.label(for: $0) }.joined(separator: ", ")
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
          let label = await NativePropertyValue.referenceLabels(field: field, value: value) {
            try await workspace.referenceRows(view: $0)
          }
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
