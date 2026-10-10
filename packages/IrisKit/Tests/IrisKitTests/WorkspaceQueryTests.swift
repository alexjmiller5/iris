import Foundation
import Testing

@testable import IrisKit

@MainActor
struct WorkspaceQueryTests {
  @Test func sortAndCombinedFiltersExecuteInSQLiteAndResetForAnotherTable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    await model.searchIndexSettled()  // the index builds in the background after open
    let workspace = try #require(model.client)
    for (title, status) in [
      ("Zulu fixture", "Ready"), ("Alpha fixture", "Draft"), ("Bravo fixture", "Ready"),
    ] {
      _ = try await workspace.write(
        table: "notes", patch: ["title": .string(title), "status": .string(status)])
    }
    model.sortColumn = "title"
    model.sortAscending = false
    model.filters = [WorkspaceFilter(column: "status", operation: .eq, value: "Ready")]
    await model.reload()
    #expect(model.rows.map(\.label) == ["Zulu fixture", "Bravo fixture"])
    model.filters.append(WorkspaceFilter(column: "title", operation: .contains, value: "Bravo"))
    await model.reload()
    #expect(model.rows.map(\.label) == ["Bravo fixture"])
    model.filters = []
    model.sortAscending = true
    model.search = "fixture"
    await model.reload()
    #expect(model.rows.map(\.label) == ["Alpha fixture", "Bravo fixture", "Zulu fixture"])
    model.table = "history"
    #expect(model.filters.isEmpty)
    #expect(model.sortColumn.isEmpty)
    #expect(model.search.isEmpty)
    await model.close()
  }

  @Test func mixedAllDayAndTimedFieldAcceptsToday() throws {
    let field = CatalogField(property: ["col": .string("due"), "type": .string("date_or_datetime")])
    var filter = WorkspaceFilter(column: "due", operation: .lte)
    filter.today = true
    #expect(try filter.coreFilter(field: field) == CoreFilter(column: "due", op: .lte, relative: .today))
  }

  @Test func typedFilterValuesAndEmptyOperatorsPreserveMeaning() throws {
    let number = CatalogField(property: ["col": .string("quantity"), "type": .string("int")])
    let boolean = CatalogField(property: ["col": .string("done"), "type": .string("bool")])
    let numeric = try WorkspaceFilter(column: "quantity", operation: .gte, value: "12.5")
      .coreFilter(field: number)
    #expect(numeric.value == .number(12.5))
    let decimal = CatalogField(property: ["col": .string("amount"), "type": .string("number")])
    #expect(
      try WorkspaceFilter(column: "amount", operation: .lt, value: "1.25").coreFilter(
        field: decimal
      ).value == .number(1.25))
    let bool = try WorkspaceFilter(column: "done", operation: .eq, value: "false").coreFilter(
      field: boolean)
    #expect(bool.value == .bool(false))
    let empty = try WorkspaceFilter(column: "quantity", operation: .empty, value: "ignored")
      .coreFilter(field: number)
    #expect(empty.value == nil)
    #expect(throws: WorkspaceError.self) {
      try WorkspaceFilter(column: "quantity", operation: .gte, value: "invalid").coreFilter(
        field: number)
    }
    #expect(!WorkspaceFilter.operations(for: "number").contains(.contains))
    #expect(WorkspaceFilter.operations(for: "multi_ref") == [.contains, .empty, .notEmpty])
    let reference = CatalogField(property: [
      "col": .string("related"), "type": .string("multi_ref"),
    ])
    #expect(
      try WorkspaceFilter(column: "related", operation: .contains, value: "chosen-id").coreFilter(
        field: reference
      ).value == .string("chosen-id"))
  }

  @Test func foregroundCalendarChangeInvalidatesTheQueryAndTodaySurvivesImport() throws {
    let model = WorkspaceModel()
    model.viewTimeZone = "America/New_York"
    let field = CatalogField(property: ["col": .string("created_at"), "type": .string("datetime")])
    let source = CoreFilter(column: "created_at", op: .lte, relative: .today)
    let filter = WorkspaceFilter(source, field: field)
    #expect(try filter.coreFilter(field: field) == source)
    model.filters = [filter]
    try model.refreshCalendar(now: ISO8601DateFormatter().date(from: "2026-03-09T03:59:59Z")!)
    let before = model.queryKey
    try model.refreshCalendar(now: ISO8601DateFormatter().date(from: "2026-03-09T04:00:00Z")!)
    #expect(model.calendarDay == "2026-03-09")
    #expect(model.queryKey != before)
  }

  @Test func optionsFromAClosedEditorCannotChangeAnotherTable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    model.table = "history"
    #expect(throws: WorkspaceError.self) {
      try model.applyViewOptions(
        sortColumn: "title", ascending: true, filters: [], context: context)
    }
    #expect(model.sortColumn.isEmpty)
    await model.close()
  }
}
