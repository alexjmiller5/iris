import Foundation
import Testing

@testable import IrisKit

@MainActor
struct TaskDayQueryTests {
  @Test func selectedPolicyRoundTripsAndResetRestoresMidnight() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    var definition = CoreSavedViewDefinition(
      version: 2, filters: [CoreFilter(column: "created_at", op: .lte, relative: .today)],
      timeZone: "America/New_York")
    definition.dayStartMinutes = 180
    let saved = try await context.workspace.saveView(
      CoreSaveViewArgs(table: context.table, name: "Late day", definition: definition))
    try model.applySavedView(saved, context: context)
    #expect(model.viewDayStartMinutes == 180)
    #expect(try model.currentViewDefinition() == definition)
    try model.refreshCalendar(now: instant("2026-06-02T06:59:59Z"))
    #expect(model.calendarDay == "2026-06-01")
    let query = model.queryKey
    try model.refreshCalendar(now: instant("2026-06-02T07:00:00Z"))
    #expect(model.calendarDay == "2026-06-02")
    #expect(model.queryKey != query)
    let refresh = model.calendarRefreshKey
    model.viewDayStartMinutes = 0
    #expect(model.calendarRefreshKey != refresh)
    #expect(try model.currentViewDefinition().dayStartMinutes == 0)
    try model.applySavedView(nil, context: context)
    #expect(model.viewDayStartMinutes == 0)
    #expect(try model.currentViewDefinition().dayStartMinutes == nil)
    try model.applySavedView(saved, context: context)
    model.table = "history"
    #expect(model.viewDayStartMinutes == 0)
    await model.close()
  }

  @Test func boundaryAndTimezoneChangesInvalidateQueryAndSleepEvenWithinTheSameDay() throws {
    let model = WorkspaceModel()
    model.viewTimeZone = "UTC"
    model.filters = [WorkspaceFilter(CoreFilter(column: "created_at", op: .lte, relative: .today))]
    try model.refreshCalendar(now: instant("2026-06-02T12:00:00Z"))
    let query = model.queryKey
    let refresh = model.calendarRefreshKey
    model.viewDayStartMinutes = 180
    #expect(model.queryKey != query)
    #expect(model.calendarRefreshKey != refresh)
    let changed = model.calendarRefreshKey
    model.viewTimeZone = "Asia/Kathmandu"
    #expect(model.calendarRefreshKey != changed)
  }

  private func instant(_ text: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: text))
  }
}
