import Foundation
import Testing

@testable import IrisKit

@MainActor
struct SyncStatusPillTests {
  private func status(pending: Int = 0, rejected: Int = 0, synced: Bool = true)
    -> WorkspaceSyncStatus
  {
    WorkspaceSyncStatus(
      lastSuccessfulSync: synced ? "2026-10-08T00:00:00.000Z" : nil, pendingUiEdits: pending,
      rejected: rejected, skippedTables: [])
  }

  private func pill(
    replica: Bool = true, syncing: Bool = false, moved: Int = 0, online: Bool = true,
    failure: String? = nil, status: WorkspaceSyncStatus? = nil, cli: Bool = false
  ) -> String {
    SyncPill.make(
      replica: replica, syncing: syncing, movedRows: moved, online: online,
      failure: failure.map(SyncFailure.init), status: status ?? self.status(), cliBound: cli
    ).title
  }

  @Test func mapsEveryHubStateToOneShortTitle() {
    #expect(pill() == "Synced")
    #expect(pill(status: status(pending: 2)) == "2 pending")
    #expect(pill(syncing: true, status: status(pending: 1)) == "Syncing")
    #expect(pill(syncing: true, moved: 40) == "Syncing")
    #expect(pill(syncing: true, status: status(synced: false)) == "Syncing")
    #expect(pill(online: false, status: status(pending: 3)) == "Offline · 3 pending")
    #expect(pill(online: false) == "Offline")
    #expect(pill(failure: HubTransport.unreachableMessage) == "Offline")
    #expect(pill(failure: "Hub HTTP 503.", status: status(pending: 1)) == "Offline · 1 pending")
    #expect(pill(status: status(rejected: 2)) == "2 rejected")
    #expect(pill(failure: "Hub HTTP 429.") == "Paused: cap reached")
    #expect(pill(failure: "Hub HTTP 401.") == "Sync issue")
  }

  @Test func aQuietPillNamesHowTheWakeSocketStands() {
    func titled(_ liveness: SyncLiveness, pending: Int = 0, online: Bool = true) -> String {
      SyncPill.make(
        replica: true, syncing: false, movedRows: 0, online: online, failure: nil,
        status: status(pending: pending), cliBound: false, liveness: liveness
      ).title
    }
    #expect(titled(.live) == "Live")
    #expect(titled(.reconnecting) == "Reconnecting")
    #expect(titled(.minute) == "Checking every minute")
    #expect(titled(.live, pending: 1) == "1 pending")
    #expect(titled(.live, online: false) == "Offline")
  }

  @Test func quietPeriodicRoundsDoNotFlickerToSyncing() {
    // A 2-second catch-up that moves nothing keeps the steady state.
    #expect(pill(syncing: true) == "Synced")
    #expect(pill(syncing: true, status: status(rejected: 1)) == "1 rejected")
    #expect(pill(syncing: true, failure: "Hub HTTP 429.") == "Paused: cap reached")
  }

  @Test func priorityKeepsTheActionableStateVisible() {
    #expect(pill(online: false, failure: "Hub HTTP 429.") == "Paused: cap reached")
    #expect(pill(online: false, status: status(pending: 1, rejected: 2)) == "2 rejected")
    #expect(pill(failure: "Hub HTTP 500.", status: status(pending: 1)) == "Offline · 1 pending")
  }

  @Test func aCatchingUpSearchIndexShowsAfterSyncWorkOnEveryKindOfDatabase() {
    func titled(
      _ indexing: Int, replica: Bool = true, pending: Int = 0, online: Bool = true,
      cli: Bool = false
    ) -> String {
      SyncPill.make(
        replica: replica, syncing: false, movedRows: 0, online: online, failure: nil,
        status: status(pending: pending), cliBound: cli, liveness: .live, indexing: indexing
      ).title
    }
    #expect(titled(1200) == "Indexing search…")
    #expect(titled(0) == "Live")
    #expect(titled(5, pending: 1) == "1 pending")
    #expect(titled(5, online: false) == "Offline")
    #expect(titled(5, replica: false, cli: true) == "Indexing search…")
    #expect(titled(5, replica: false) == "Indexing search…")
    #expect(titled(0, replica: false) == "Local only")
  }

  @Test func sharedFilesReflectTheCLIAndNeverOfferSync() {
    #expect(pill(replica: false, cli: true) == "Shared with CLI")
    #expect(
      pill(replica: false, online: false, failure: "Hub HTTP 429.", cli: true)
        == "Shared with CLI")
    #expect(pill(replica: false) == "Local only")
  }

  #if os(macOS)
    @Test func menuBarListsTitlesOnlyAndSkipsUnusableDestinations() {
      var ready = NativeRecentEntry(destination: NativeDestination(table: "notes"), label: "notes")
      ready.loading = false
      var record = NativeRecentEntry(
        destination: NativeDestination(table: "notes", rowID: "n1"), label: "Plan trip")
      record.loading = false
      var missing = NativeRecentEntry(destination: NativeDestination(table: "gone"), label: "gone")
      missing.loading = false
      missing.unavailable = "Table removed"
      let loading = NativeRecentEntry(destination: NativeDestination(table: "x"), label: "x")
      let extra = (0..<6).map { index in
        var entry = NativeRecentEntry(
          destination: NativeDestination(table: "t\(index)"), label: "t\(index)")
        entry.loading = false
        return entry
      }
      let pins = [
        CoreSidebarPin(
          id: "p1", tbl: "places", position: 0, updatedAt: "2026-10-08T00:00:00.000Z",
          deletedAt: nil, unavailable: nil),
        CoreSidebarPin(
          id: "p2", tbl: "secret", position: 1, updatedAt: "2026-10-08T00:00:00.000Z",
          deletedAt: nil, unavailable: "Not downloaded"),
      ]
      let synced = SyncPill.make(
        replica: true, syncing: false, movedRows: 0, online: true, failure: nil,
        status: status(), cliBound: false)
      let menu = WorkspaceMenuBar.menu(
        pill: synced, recents: [ready, record, missing, loading] + extra, pins: pins)
      #expect(menu.status == "Synced")
      #expect(menu.symbol == synced.symbol)
      #expect(menu.canFind)
      #expect(menu.recents.map(\.title) == ["notes", "Plan trip", "t0", "t1", "t2"])
      #expect(menu.recents[1].destination == NativeDestination(table: "notes", rowID: "n1"))
      #expect(menu.pinned.map(\.title) == ["places"])
      #expect(menu.pinned[0].destination == NativeDestination(table: "places"))

      let closed = WorkspaceMenuBar.menu(pill: nil, recents: [], pins: [])
      #expect(closed.status == "No workspace open")
      #expect(!closed.canFind)
      #expect(closed.recents.isEmpty && closed.pinned.isEmpty)
    }

    @Test func menuBarCommandsReachOnlyTheAttachedWindowOnce() {
      let bar = WorkspaceMenuBar()
      let first = WorkspaceModel()
      let second = WorkspaceModel()
      bar.attach(first)
      bar.attach(second)
      bar.send(.quickFind)
      #expect(bar.take(for: first) == nil)
      #expect(bar.take(for: second) == .quickFind)
      #expect(bar.take(for: second) == nil)
      bar.send(.open(NativeDestination(table: "notes")))
      bar.detach(first)
      #expect(bar.take(for: second) == .open(NativeDestination(table: "notes")))
      bar.detach(second)
      #expect(bar.menu.status == "No workspace open")
    }
  #endif
}
