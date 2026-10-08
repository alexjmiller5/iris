import SwiftUI

/// Sort popover: ordered rules with a direction toggle each, drag to reorder.
/// Every change applies immediately; the bar saves the view on dismiss.
struct SortMenu: View {
  let model: WorkspaceModel

  private var fields: [CatalogField] { model.viewFields }
  private var sorts: [CoreSort] { model.sortRules }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(Array(sorts.enumerated()), id: \.element.column) { index, sort in
            row(sort, index: index)
          }
          .onMove { from, to in
            var next = sorts
            next.move(fromOffsets: from, toOffset: to)
            model.setSorts(next)
          }
          if sorts.isEmpty {
            Text("Records keep their default order.").foregroundStyle(.secondary)
          }
        } footer: {
          if sorts.count > 1 { Text("Drag rules to change their priority.") }
        }
        Section {
          Menu {
            ForEach(fields.filter { field in !sorts.contains { $0.column == field.id } }) {
              field in
              Button(field.label) {
                model.setSorts(sorts + [CoreSort(column: field.id, direction: .asc)])
              }
            }
          } label: {
            Label("Add sort", systemImage: "plus")
          }
          .disabled(sorts.count >= 16)
          .accessibilityIdentifier("add-sort")
          if !sorts.isEmpty {
            Button("Delete all sorts", role: .destructive) { model.setSorts([]) }
              .accessibilityIdentifier("clear-sorts")
          }
        }
      }
      #if os(iOS)
        // Drag handles stay visible, as in Notion; row controls remain usable.
        .environment(\.editMode, .constant(.active))
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .navigationTitle("Sort")
    }
  }

  private func row(_ sort: CoreSort, index: Int) -> some View {
    let field = fields.first { $0.id == sort.column }
    let label = field?.label ?? sort.column
    let ascending = sort.direction == .asc
    return HStack(spacing: 8) {
      Text(label).lineLimit(1)
      Spacer(minLength: 4)
      if ["select", "multi_select"].contains(field?.type ?? "") {
        Button {
          update(index) { $0.mode = $0.mode == .options ? nil : .options }
        } label: {
          Text(sort.mode == .options ? "Option order" : "A–Z").font(.caption)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .accessibilityLabel("Compare by \(sort.mode == .options ? "option order" : "value")")
        .accessibilityHint("Switches how \(label) is compared")
      }
      Button {
        update(index) { $0.direction = ascending ? .desc : .asc }
      } label: {
        Label(
          ascending ? "Ascending" : "Descending",
          systemImage: ascending ? "arrow.up" : "arrow.down")
      }
      .buttonStyle(.bordered).controlSize(.small)
      .accessibilityLabel("\(label), \(ascending ? "ascending" : "descending")")
      .accessibilityHint("Reverses the direction")
      .accessibilityIdentifier("sort-direction-\(index)")
      Button {
        var next = sorts
        next.remove(at: index)
        model.setSorts(next)
      } label: {
        Image(systemName: "xmark").foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove sort by \(label)")
      .accessibilityIdentifier("remove-sort-\(index)")
    }
  }

  private func update(_ index: Int, _ change: (inout CoreSort) -> Void) {
    var next = sorts
    guard next.indices.contains(index) else { return }
    change(&next[index])
    model.setSorts(next)
  }
}
