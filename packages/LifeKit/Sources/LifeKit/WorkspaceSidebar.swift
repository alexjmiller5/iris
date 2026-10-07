import SwiftUI

struct WorkspaceSidebar: View {
  let tables: NativeSidebarTables
  let recents: NativeRecentsModel?
  let pins: NativePinsModel?
  let selectedTable: String?
  let disabled: Bool
  let error: String?
  let onOpen: (NativeDestination) -> Void
  @State private var systemExpanded = false

  var body: some View {
    if let error {
      Text(error).font(.callout).foregroundStyle(.red)
        .accessibilityIdentifier("sidebar-navigation-error")
    }
    if let recents {
      RecentDestinations(recents: recents, disabled: disabled, onOpen: onOpen)
    }
    if let pins {
      PinnedTablesSection(pins: pins, selected: selectedTable, disabled: disabled, onOpen: onOpen)
    }
    Section("Tables") {
      ForEach(tables.ordinary) { table in
        SidebarTableRow(table: table, selected: selectedTable == table.id, disabled: disabled,
          pinDisabled: pins?.disabled ?? true, onPin: { Task { await pins?.pin(table.id) } }) {
          onOpen(NativeDestination(table: table.id))
        }
      }
    }
    if !tables.system.isEmpty {
      DisclosureGroup("System tables", isExpanded: $systemExpanded) {
        ForEach(tables.system) { table in
          SidebarTableRow(table: table, selected: selectedTable == table.id, disabled: disabled,
          pinDisabled: pins?.disabled ?? true, onPin: { Task { await pins?.pin(table.id) } }) {
            onOpen(NativeDestination(table: table.id))
          }
        }
      }
      .onChange(of: selectedTable, initial: true) {
        if tables.system.contains(where: { $0.id == selectedTable }) { systemExpanded = true }
      }
    }
  }
}

private struct SidebarTableRow: View {
  let table: NativeSidebarTable
  let selected: Bool
  let disabled: Bool
  var pinDisabled = true
  var onPin: (() -> Void)? = nil
  let onOpen: () -> Void

  var body: some View {
    HStack {
    Button(action: onOpen) {
      Label {
        VStack(alignment: .leading, spacing: 3) {
          Text(table.id).foregroundStyle(.primary)
          if let purpose = table.purpose {
            Text(purpose).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      } icon: {
        Image(systemName: "tablecells")
      }.contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("sidebar-table-" + table.id)
    if let onPin {
      Button(action: onPin) { Image(systemName: "pin").frame(minWidth: 32, minHeight: 36) }
        .buttonStyle(.borderless).disabled(disabled || pinDisabled)
        .accessibilityLabel("Pin \(table.id)").help("Pin table")
    }
    }
  }
}

private struct RecentDestinations: View {
  let recents: NativeRecentsModel
  let disabled: Bool
  let onOpen: (NativeDestination) -> Void

  var body: some View {
    Section("Recents") {
      if recents.entries.isEmpty {
        Text("Opened tables, views and records appear here.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(recents.entries) { entry in
        RecentDestinationRow(
          entry: entry, disabled: disabled,
          onOpen: { onOpen(entry.destination) },
          onRemove: { Task { await recents.remove(entry.destination) } })
      }
      if let error = recents.storageError {
        Text(error).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("recents-storage-error")
      }
    }
  }
}

private struct RecentDestinationRow: View {
  let entry: NativeRecentEntry
  let disabled: Bool
  let onOpen: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      VStack(alignment: .leading, spacing: 3) {
        Button(action: onOpen) {
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.label).foregroundStyle(.primary).lineLimit(2)
            if entry.destination.rowID != nil {
              Text("Record · \(entry.destination.table)").font(.caption).foregroundStyle(.secondary)
            } else if entry.destination.viewID != nil {
              Text("View · \(entry.destination.table)").font(.caption).foregroundStyle(.secondary)
            } else {
              Text("Table").font(.caption).foregroundStyle(.secondary)
            }
            if entry.isTrashed {
              Label("In Trash", systemImage: "trash").font(.caption).foregroundStyle(.secondary)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .disabled(disabled || entry.loading || entry.unavailable != nil)
        .accessibilityIdentifier("open-recent")
        if let reason = entry.unavailable {
          Text(reason).font(.caption).foregroundStyle(.secondary)
        }
      }
      if entry.loading { ProgressView().controlSize(.small).accessibilityLabel("Loading recent") }
      Button(action: onRemove) {
        Image(systemName: "xmark").frame(minWidth: 28, minHeight: 28)
      }
      .disabled(disabled)
      .accessibilityLabel("Remove recent \(entry.label)")
      .accessibilityIdentifier("remove-recent")
      .help("Remove from Recents")
    }.buttonStyle(.borderless)
  }
}
