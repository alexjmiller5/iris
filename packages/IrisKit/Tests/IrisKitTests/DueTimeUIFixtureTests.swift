import Foundation
import Testing

@testable import IrisKit

/// Seeds the app's own local workspace on one explicit simulator for `DueTimeUITests`:
/// a `due` mixed date on notes, a fixture note due today and a "Due today" Now view.
/// Plain SQL, like the other UI fixtures, so rules another fixture enforced on this
/// simulator's workspace cannot refuse the seed.
@MainActor
struct DueTimeUIFixtureTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["IRIS_TEST_DUE_TIME_SIMULATOR"] != nil))
    func prepareDueTimeUIFixture() async throws {
      let env = ProcessInfo.processInfo.environment
      try #require(env["IRIS_TEST_DUE_TIME_SIMULATOR"] == env["SIMULATOR_UDID"])
      let model = WorkspaceModel()
      try await model.forgetConnection()
      await model.open()
      await model.close()
      let runtime = try await IrisCoreRuntime.onCore()
      let workspace = try await NativeWorkspace(
        path: WorkspaceModel.localURL().path, runtime: runtime)
      let today = NativeDateValue.currentValue(at: Date(), kind: .date)
      let definition = String(
        decoding: try JSONEncoder().encode(
          CoreSavedViewDefinition(
            version: 2, filters: [CoreFilter(column: "due", op: .lte, relative: .now)])),
        as: UTF8.self)
      await runtime.evaluateOnCore(
        """
        if (!IrisSql.all("SELECT 1 FROM pragma_table_info('notes') WHERE name='due'").length)
          IrisSql.run('ALTER TABLE notes ADD COLUMN due TEXT');
        IrisSql.run("INSERT OR REPLACE INTO catalog_properties(id,tbl,col,label,type,sort) VALUES ('notes.due','notes','due','Due','date_or_datetime',5)");
        IrisSql.run("INSERT OR REPLACE INTO notes(id,title,due) VALUES ('due-fixture-note','Due fixture note',?)", [\(String(reflecting: today))]);
        IrisSql.run("INSERT OR REPLACE INTO views(id,name,tbl,definition) VALUES ('due-fixture-view','Due today','notes',?)", [\(String(reflecting: definition))]);
        """)
      try #require(runtime.context.exception == nil)
      try await workspace.close()
    }
  #endif
}
