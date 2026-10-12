import SwiftUI

/// Pinned tables reorder by dragging their three-bar handle and unpin from the row's
/// context menu: long press on iPhone, right-click on Mac.
struct PinnedTablesSection: View {
  let pins: NativePinsModel
  let selected: String?
  let disabled: Bool
  let onOpen: (NativeDestination) -> Void
  /// The dragged pin and the index it would land on.
  @State private var drag: (id: String, from: Int, to: Int)?
  /// Each row's vertical centre in global coordinates, for the landing index.
  @State private var centres: [String: CGFloat] = [:]

  var body: some View {
    if !pins.active.isEmpty {
      Section("Pinned tables") {
        ForEach(Array(pins.active.enumerated()), id: \.element.id) { index, pin in
          PinnedTableRow(
            pin: pin, selected: selected == pin.tbl, disabled: disabled,
            mutationDisabled: pins.disabled,
            first: index == 0, last: index == pins.active.count - 1,
            dragging: drag?.id == pin.id, landing: landing(at: index),
            onOpen: { onOpen(NativeDestination(table: pin.tbl)) },
            onUnpin: { Task { await pins.unpin(pin.id) } },
            onMove: { offset in Task { await pins.reorder(pin.id, to: index + offset) } },
            onCentre: { centres[pin.id] = $0 },
            onDrag: { y in
              guard !(disabled || pins.disabled) else { return }
              // It lands after every other row whose centre it passed (web `dropIndex`).
              let to = pins.active.filter { $0.id != pin.id && (centres[$0.id] ?? .infinity) < y }.count
              drag = (pin.id, index, to)
            },
            onDrop: {
              guard let done = drag else { return }
              drag = nil
              if done.to != done.from { Task { await pins.reorder(done.id, to: done.to) } }
            })
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

  /// The edge of the row at `index` where the dragged pin would land.
  private func landing(at index: Int) -> VerticalEdge? {
    guard let drag, drag.to == index, drag.to != drag.from else { return nil }
    return drag.to < drag.from ? .top : .bottom
  }
}

private struct PinnedTableRow: View {
  let pin: CoreSidebarPin
  let selected: Bool
  let disabled: Bool
  let mutationDisabled: Bool
  let first: Bool
  let last: Bool
  let dragging: Bool
  let landing: VerticalEdge?
  let onOpen: () -> Void
  let onUnpin: () -> Void
  let onMove: (Int) -> Void
  let onCentre: (CGFloat) -> Void
  let onDrag: (CGFloat) -> Void
  let onDrop: () -> Void

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
        // Drag and the context menu have no VoiceOver gesture of their own.
        .accessibilityActions {
          if !(disabled || mutationDisabled) {
            if !first { Button("Move up") { onMove(-1) } }
            if !last { Button("Move down") { onMove(1) } }
            Button("Unpin", action: onUnpin)
          }
        }
        if let unavailable = pin.unavailable {
          Text(unavailable).font(.caption).foregroundStyle(.secondary)
        }
      }
      // Dragging starts on touch, so it never waits for the long-press menu.
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.secondary)
        .frame(minWidth: 32, minHeight: 32)
        .contentShape(.rect)
        .help("Drag to reorder")
        .gesture(
          DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { onDrag($0.location.y) }
            .onEnded { _ in onDrop() })
        .accessibilityHidden(true)
    }
    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { onCentre($0) }
    .overlay(alignment: landing == .bottom ? .bottom : .top) {
      if landing != nil { Rectangle().fill(Color.accentColor).frame(height: 2) }
    }
    .contextMenu {
      Button("Unpin", systemImage: "trash", role: .destructive, action: onUnpin)
        .disabled(disabled || mutationDisabled)
    }
    .listRowBackground(
      dragging || selected ? Color.accentColor.opacity(dragging ? 0.2 : 0.12) : Color.clear)
  }
}
