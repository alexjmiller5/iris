import SwiftUI

struct NativePresentationControls: View {
  @Binding var value: CoreViewPresentation
  let fields: [CatalogField]
  private var dates: [CatalogField] {
    fields.filter {
      $0.property["deprecated"]?.isTrue != true
        && ["date", "datetime", "date_or_datetime"].contains($0.type)
    }
  }
  private var covers: [CatalogField] {
    fields.filter {
      $0.property["deprecated"]?.isTrue != true && ["text", "url", "json"].contains($0.type)
    }
  }
  private var groups: [CatalogField] {
    fields.filter { $0.property["deprecated"]?.isTrue != true && $0.type == "select" }
  }
  var body: some View {
    Section("Layout") {
      Picker(
        "View layout",
        selection: Binding(
          get: { value.kind },
          set: { kind in
            value = CoreViewPresentation(
              kind: kind,
              dateColumn: kind == "calendar" ? dates.first?.id : nil,
              groupColumn: kind == "board" ? groups.first?.id : nil)
          })
      ) {
        Text("Table").tag("table")
        Text("Calendar").tag("calendar").disabled(dates.isEmpty)
        Text("Gallery").tag("gallery")
        Text("Board").tag("board").disabled(groups.isEmpty)
      }.accessibilityIdentifier("view-layout")
      if value.kind == "calendar" {
        property("Date", selection: $value.dateColumn, choices: dates, empty: nil)
        property("End date", selection: $value.endDateColumn, choices: dates, empty: "Single date")
      } else if value.kind == "gallery" {
        property("Cover", selection: $value.coverColumn, choices: covers, empty: "No cover")
      } else if value.kind == "board" {
        property("Group by", selection: $value.groupColumn, choices: groups, empty: nil)
      }
    }
  }
  private func property(
    _ label: String, selection: Binding<String?>, choices: [CatalogField], empty: String?
  ) -> some View {
    Picker(
      label,
      selection: Binding(
        get: { selection.wrappedValue ?? "" },
        set: { selection.wrappedValue = $0.isEmpty ? nil : $0 })
    ) {
      if let empty { Text(empty).tag("") }
      ForEach(choices) { field in Text(field.label).tag(field.id) }
    }
  }
}
