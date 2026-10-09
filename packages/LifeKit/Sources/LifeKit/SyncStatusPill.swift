import Network
import SwiftUI

/// Why the last automatic round failed, as far as the user can act on it.
enum SyncFailure: Equatable {
  case offline, capped, other

  /// Transport failures cross the JS core as text; the prefixes are HubTransport's own.
  init(_ message: String) {
    if message.contains(HubTransport.unreachableMessage) || message.contains("Hub HTTP 5") {
      self = .offline
    } else if message.contains("Hub HTTP 429") {
      self = .capped
    } else {
      self = .other
    }
  }
}

/// The one sync summary every surface shows (sidebar, toolbar, menu bar).
struct SyncPill: Equatable {
  enum Kind: Equatable {
    case synced, syncing, pending, offline, rejected, paused, failed, cli, local
  }
  let kind: Kind
  let title: String
  let symbol: String

  /// Background catch-up runs every few seconds; it only reads as "Syncing" while
  /// something actually moves (pending uploads, received rows or a first download).
  static func make(
    replica: Bool, syncing: Bool, movedRows: Int, online: Bool, failure: SyncFailure?,
    status: WorkspaceSyncStatus?, cliBound: Bool
  ) -> SyncPill {
    guard replica else {
      return cliBound
        ? SyncPill(kind: .cli, title: "Shared with CLI", symbol: "terminal")
        : SyncPill(kind: .local, title: "Local only", symbol: "internaldrive")
    }
    let pending = status?.pendingUiEdits ?? 0
    let rejected = status?.rejected ?? 0
    if failure == .capped {
      return SyncPill(kind: .paused, title: "Paused: cap reached", symbol: "pause.circle")
    }
    if rejected > 0 {
      return SyncPill(
        kind: .rejected, title: "\(rejected) rejected", symbol: "exclamationmark.triangle")
    }
    if !online || failure == .offline {
      return SyncPill(
        kind: .offline, title: pending > 0 ? "Offline · \(pending) pending" : "Offline",
        symbol: "icloud.slash")
    }
    if failure == .other {
      return SyncPill(kind: .failed, title: "Sync issue", symbol: "exclamationmark.icloud")
    }
    if syncing && (pending > 0 || movedRows > 0 || status?.lastSuccessfulSync == nil) {
      return SyncPill(kind: .syncing, title: "Syncing", symbol: "arrow.triangle.2.circlepath")
    }
    if pending > 0 {
      return SyncPill(kind: .pending, title: "\(pending) pending", symbol: "clock")
    }
    return SyncPill(kind: .synced, title: "Synced", symbol: "checkmark.icloud")
  }
}

/// System connectivity changes; offline pauses automatic sync until a path returns.
func networkReachability() -> AsyncStream<Bool> {
  AsyncStream { continuation in
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
    continuation.onTermination = { _ in monitor.cancel() }
    monitor.start(queue: DispatchQueue(label: "life-ui.network-path"))
  }
}

/// Read-only status; tapping opens details (or the rejection inbox). No sync action.
struct SyncStatusPill: View {
  let pill: SyncPill
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      // Toolbars collapse a Label to its icon; the pill always shows its words.
      // The words carry the state, so they keep full contrast; the symbol is tinted.
      HStack(spacing: 4) {
        Image(systemName: pill.symbol).foregroundStyle(tint)
        Text(pill.title).foregroundStyle(.primary)
      }
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .fixedSize()
      #if os(macOS)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .capsule)
      #endif
    }
    #if os(macOS)
      .buttonStyle(.plain)
    #endif
    .accessibilityIdentifier("workspace-status")
    // A bar item cannot grow with Dynamic Type; a long press shows it large.
    .accessibilityShowsLargeContentViewer()
    .accessibilityLabel(pill.title)
    .accessibilityHint("Shows sync details")
    .help("Show sync details")
  }

  private var tint: Color {
    switch pill.kind {
    case .rejected, .failed: .red
    case .offline, .paused, .pending: .orange
    case .synced, .syncing, .cli, .local: .secondary
    }
  }
}

#Preview("Sync pill states") {
  let status = { (pending: Int, rejected: Int) in
    WorkspaceSyncStatus(
      lastSuccessfulSync: "2026-10-08T00:00:00.000Z", pendingUiEdits: pending, rejected: rejected,
      skippedTables: [])
  }
  VStack(alignment: .leading, spacing: 12) {
    ForEach(
      [
        SyncPill.make(
          replica: true, syncing: false, movedRows: 0, online: true, failure: nil,
          status: status(0, 0), cliBound: false),
        SyncPill.make(
          replica: true, syncing: true, movedRows: 0, online: true, failure: nil,
          status: status(1, 0), cliBound: false),
        SyncPill.make(
          replica: true, syncing: false, movedRows: 0, online: false, failure: nil,
          status: status(3, 0), cliBound: false),
        SyncPill.make(
          replica: true, syncing: false, movedRows: 0, online: true, failure: nil,
          status: status(0, 2), cliBound: false),
        SyncPill.make(
          replica: true, syncing: false, movedRows: 0, online: true, failure: .capped,
          status: status(0, 0), cliBound: false),
      ], id: \.title
    ) { SyncStatusPill(pill: $0) {} }
  }.padding()
}
