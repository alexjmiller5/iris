import SwiftUI

struct PinnedTablesSection: View {
  let pins: NativePinsModel
  let selected: String?
  let disabled: Bool
  let onOpen: (NativeDestination) -> Void

  var body: some View {
    if !pins.active.isEmpty {
      Section("Pinned tables") {
        ForEach(pins.active, id: \.id) { pin in
          PinnedTableRow(
            pin: pin, selected: selected == pin.tbl, disabled: disabled,
            mutationDisabled: pins.disabled,
            first: pins.active.first?.id == pin.id, last: pins.active.last?.id == pin.id,
            onOpen: { onOpen(NativeDestination(table: pin.tbl)) },
            onUnpin: { Task { await pins.unpin(pin.id) } },
            onMove: { direction in Task { await pins.move(pin.id, direction: direction) } })
        }
      }
    }
    if let message = pins.error ?? pins.snapshot?.unavailable {
      Section {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("sidebar-pins-error")
        Button("Retry pins") { Task { await pins.refresh() } }.disabled(disabled || pins.busy)
      }
    }
  }
}

private struct PinnedTableRow: View {
  let pin: CoreSidebarPin
  let selected: Bool
  let disabled: Bool
  let mutationDisabled: Bool
  let first: Bool
  let last: Bool
  let onOpen: () -> Void
  let onUnpin: () -> Void
  let onMove: (String) -> Void

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        Button(action: onOpen) {
          Label(pin.tbl, systemImage: "pin.fill")
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(disabled || pin.unavailable != nil)
        .accessibilityLabel("Open pinned \(pin.tbl)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-pinned-" + pin.tbl)
        if let unavailable = pin.unavailable {
          Text(unavailable).font(.caption).foregroundStyle(.secondary)
        }
      }
      Menu {
        Button("Move up", systemImage: "chevron.up") { onMove("up") }.disabled(first)
        Button("Move down", systemImage: "chevron.down") { onMove("down") }.disabled(last)
        Button("Unpin", systemImage: "pin.slash", action: onUnpin)
      } label: {
        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
      }
      .disabled(disabled || mutationDisabled)
      .accessibilityLabel("Pin actions for \(pin.tbl)")
    }
    .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
  }
}
