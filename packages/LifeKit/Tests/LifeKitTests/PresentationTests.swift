import Foundation
import JavaScriptCore
import Testing

@testable import LifeKit

@MainActor struct PresentationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_PRESENTATION_DATABASE"] != nil))
  func preparePresentationUIFixture() async throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["LIFE_UI_TEST_PRESENTATION_DATABASE"])
    try #require(URL(fileURLWithPath: path).lastPathComponent == "presentation-acceptance.sqlite")
    try #require(!FileManager.default.fileExists(atPath: path))
    let runtime = try LifeCoreRuntime()
    let workspace = try NativeWorkspace(path: path, runtime: runtime)
    try await workspace.createSample()
    let month = try calendarContext(timeZone: TimeZone.current.identifier).today.prefix(7)
    let statements = [
      "ALTER TABLE notes ADD COLUMN starts TEXT", "ALTER TABLE notes ADD COLUMN ends TEXT",
    ]
    for ddl in statements {
      let encoded = String(data: try JSONEncoder().encode(ddl), encoding: .utf8)!
      runtime.context.evaluateScript(
        "LifeSql.run(\(encoded)); LifeSql.run('INSERT INTO _schema_log(ddl) VALUES (?)',[\(encoded)])"
      )
      try #require(runtime.context.exception == nil)
    }
    runtime.context.evaluateScript(
      """
      LifeSql.run("INSERT INTO catalog_properties(id,tbl,col,label,sort,type) VALUES ('notes.starts','notes','starts','Starts',10,'date'),('notes.ends','notes','ends','Ends',11,'date')");
      LifeSql.run("UPDATE notes SET starts='\(month)-10',ends='\(month)-12'");
      """)
    try #require(runtime.context.exception == nil)
    try await workspace.close()
  }
  @Test func explicitCoverAcceptsExtensionlessImagesButRejectsUnsafeURLs() throws {
    #expect(
      try #require(ImageReference.cover(type: "url", value: "https://images.invalid/cover?id=1"))
        .url(endpoint: nil).absoluteString == "https://images.invalid/cover?id=1")
    #expect(
      ImageReference.cover(type: "text", value: "/v1/files/opaque-key") == .retained("opaque-key"))
    #expect(ImageReference.cover(type: "json", value: #"["https://images.invalid/image"]"#) != nil)
    for value in [
      "http://images.invalid/image", "https://user:secret@images.invalid/image",
      "/v1/files/../secret", "javascript:alert(1)",
    ] {
      #expect(ImageReference.cover(type: "url", value: value) == nil)
    }
  }
  @Test func boardRoundTripsAndResetReturnsToTable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    let presentation = CoreViewPresentation(kind: "board", groupColumn: "status")
    try model.applyWorkflowOptions(
      sorts: [], filters: [], groups: [], actions: [], layout: nil,
      timeZone: "UTC", presentation: presentation, context: context)
    let definition = try model.currentViewDefinition()
    #expect(definition.version == 2)
    #expect(definition.presentation == presentation)
    let saved = try await context.workspace.saveView(
      CoreSaveViewArgs(table: context.table, name: "Board", definition: definition))
    try model.applySavedView(nil, context: context)
    #expect(model.viewPresentation.kind == "table")
    try model.applySavedView(saved, context: context)
    #expect(model.viewPresentation == presentation)
    #expect(try model.currentViewDefinition().presentation == presentation)
    await model.close()
  }
  @Test func nativeExecutesSharedCalendarAndBoardPresentation() async throws {
    let workspace = try NativeWorkspace(path: ":memory:")
    let rows: [WorkspaceRecord] = [
      [
        "id": .string("range"), "start": .string("2026-03-07"), "end": .string("2026-03-09"),
        "state": .string("Doing"),
      ],
      ["id": .string("empty"), "state": .null],
    ]
    let days = try calendarMonth("2026-03", timeZone: "America/New_York")
    let calendar = try await workspace.calendarRows(
      CoreCalendarRowsArgs(rows: rows, dateColumn: "start", endDateColumn: "end", days: days))
    #expect(
      calendar.days.filter { !$0.rowIds.isEmpty }.map(\.date) == [
        "2026-03-07", "2026-03-08", "2026-03-09",
      ])
    #expect(calendar.undated == ["empty"])
    let board = try await workspace.boardRows(
      CoreBoardRowsArgs(rows: rows, column: "state", options: ["Todo", "Doing"]))
    #expect(board.columns.map(\.value) == ["Todo", "Doing", nil])
    #expect(board.columns.map(\.rowIds) == [[], ["range"], ["empty"]])
    try await workspace.close()
  }
}
