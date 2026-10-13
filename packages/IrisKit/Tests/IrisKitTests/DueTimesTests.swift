import Foundation
import IrisExtensionSupport
import Testing

@testable import IrisKit

/// Synthetic notes with a `due` date_or_datetime column: date-only, floating local
/// times and UTC instants around 12:30 New York on 2032-10-13 (a 03:00 day start).
@MainActor struct DueTimesTests {
  static let now = ISO8601DateFormatter().date(from: "2032-10-13T16:30:00Z")!
  static let definition = CoreSavedViewDefinition(
    version: 2, filters: [
      CoreFilter(column: "status", op: .eq, value: .string("Draft")),
      CoreFilter(column: "due", op: .lte, relative: .now),
    ], timeZone: "America/New_York", dayStartMinutes: 180)

  private func fixture(_ body: (NativeWorkspace) async throws -> Void) async throws {
    let workspace = try await NativeWorkspace(path: ":memory:")
    try await workspace.createSample()
    do {
      _ = try await workspace.saveCatalogProperty(
        CoreSaveCatalogPropertyArgs(
          table: "notes", column: "due", expectedUpdatedAt: nil,
          fields: ["label": .string("Due"), "type": .string("date_or_datetime")], addColumn: true))
      for (title, due, status) in [
        ("Anytime today", "2032-10-13", "Draft"), ("Past noon", "2032-10-13T12:00", "Draft"),
        ("Evening", "2032-10-13T18:00", "Draft"), ("Instant soon", "2032-10-13T17:15:00.000Z", "Draft"),
        ("After midnight", "2032-10-14T01:00", "Draft"), ("Tomorrow noon", "2032-10-14T12:00", "Draft"),
        ("Ready evening", "2032-10-13T17:00", "Ready"), ("Next week", "2032-10-25T09:00", "Draft"),
      ] {
        _ = try await workspace.write(
          table: "notes",
          patch: ["title": .string(title), "due": .string(due), "status": .string(status)])
      }
      try await body(workspace)
    } catch {
      _ = try? await workspace.close()
      throw error
    }
    try await workspace.close()
  }

  @Test func nextDueIsTheNearestTimedValueLaterInThePolicyDay() async throws {
    try await fixture { workspace in
      let next = try await DueTimes.nextDue(
        workspace: workspace, table: "notes", columns: ["due"], timeZone: "America/New_York",
        dayStartMinutes: 180, now: Self.now)
      // 17:15 UTC beats 18:00 New York (22:00 UTC) and the 17:00 local draft-less row (21:00 UTC).
      #expect(next == ISO8601DateFormatter().date(from: "2032-10-13T17:15:00Z"))
      #expect(DueTimes.nowColumns(Self.definition) == ["due"])
      #expect(DueTimes.dueColumn(Self.definition) == "due")
    }
  }

  @Test func upcomingKeepsTheViewsOtherFiltersAndOnlySpecificTimes() async throws {
    try await fixture { workspace in
      let upcoming = try await DueTimes.upcoming(
        workspace: workspace, table: "notes", definition: Self.definition, column: "due",
        now: Self.now, days: 2)
      #expect(upcoming.map(\.label) == ["Instant soon", "Evening", "After midnight", "Tomorrow noon"])
      #expect(upcoming.first?.value == "2032-10-13T17:15:00.000Z")
      #expect(upcoming[1].at == ISO8601DateFormatter().date(from: "2032-10-13T22:00:00Z"))
      let week = try await DueTimes.upcoming(
        workspace: workspace, table: "notes", definition: Self.definition, column: "due",
        now: Self.now, days: 14)
      #expect(week.last?.label == "Next week")
    }
  }

  @Test func alertPlanIsNearestFirstCappedDedupedAndScopedToItsWorkspace() throws {
    let prefix = DueAlerts.prefix(workspaceID: "workspace")
    let link = try #require(URL(string: "iris://open/v1?fixture"))
    let requests = (0..<70).reversed().map { index in
      DueAlertRequest(
        identifier: DueAlerts.identifier(
          workspaceID: "workspace", table: "notes", rowID: "row-\(index)", value: "v"),
        title: "Row \(index)", body: "Due", link: link,
        at: Date(timeIntervalSince1970: Double(index) * 60), floating: true)
    }
    let pending = [
      requests.last!.identifier, prefix + "stale", "another-app-alert",
      DueAlerts.prefix(workspaceID: "other") + "kept",
    ]
    let plan = DueAlerts.plan(requests + [requests[0]], pending: pending, prefix: prefix)
    #expect(plan.add.count == DueAlerts.limit - 1)
    #expect(plan.add.first?.title == "Row 1")
    #expect(!plan.add.contains { $0.title == "Row 64" })
    #expect(plan.remove == [prefix + "stale"])
    #expect(
      DueAlerts.identifier(workspaceID: "workspace", table: "notes", rowID: "a", value: "2032-10-13T09:00")
        != DueAlerts.identifier(workspaceID: "workspace", table: "notes", rowID: "a", value: "2032-10-13T10:00"))
  }

  @Test func chosenViewsScheduleOnlyWithPermissionAndForgetOnRemoval() async throws {
    try await fixture { workspace in
      let view = try await workspace.saveView(
        CoreSaveViewArgs(table: "notes", name: "Due drafts", definition: Self.definition))
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let center = RecordingDueAlertCenter()
      let settings = NativeIntegrationSettings(
        workspace: workspace, workspaceID: "local:workspace", binding: .local(UUID()),
        preferencesURL: root.appendingPathComponent("integrations.json"), alerts: center)
      center.allowed = false
      #expect(await settings.setAlertViews([NativeWidgetSelection(table: "notes", viewID: view.id)]))
      #expect(center.pending.isEmpty)
      center.allowed = true
      await settings.reconcileDueAlerts(now: Self.now)
      #expect(center.pending.map(\.title) == ["Instant soon", "Evening", "After midnight", "Tomorrow noon"])
      #expect(center.pending.allSatisfy { $0.body.hasSuffix("· Due drafts") && $0.link.scheme == "iris" })
      // The view pins a zone, so its local times fire at exact instants.
      #expect(center.pending.allSatisfy { !$0.floating })
      #expect(await settings.setAlertViews([]))
      #expect(center.pending.isEmpty)
    }
  }
}

@MainActor final class RecordingDueAlertCenter: DueAlertCenter {
  var allowed = true
  var pending: [DueAlertRequest] = []
  func authorized() async -> Bool { allowed }
  func pendingIdentifiers() async -> [String] { pending.map(\.identifier) }
  func add(_ request: DueAlertRequest) async throws { pending.append(request) }
  func remove(_ identifiers: [String]) { pending.removeAll { identifiers.contains($0.identifier) } }
}
