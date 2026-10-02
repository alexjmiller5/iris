import Testing

@testable import LifeKit

@MainActor
struct WorkspaceModelTests {
  @Test func missingOrClosedWorkspaceCannotReportSaveSuccess() async throws {
    let model = WorkspaceModel()
    await #expect(throws: WorkspaceError.self) {
      try await model.save(["title": .string("Unsaved")], original: nil, context: nil)
    }
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    await model.close()
    await #expect(throws: WorkspaceError.self) {
      try await model.save(["title": .string("Unsaved")], original: nil, context: context)
    }
  }

  @Test func editorCannotWriteToAnotherWorkspaceWithTheSameTable() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    await model.open(demo: true)
    do {
      try await model.save(["title": .string("Must not appear")], original: nil, context: context)
      Issue.record("A stale editor saved into another workspace")
    } catch let error as WorkspaceError {
      #expect(error.message == "The workspace or table changed. Reopen the record before saving.")
    }
    #expect(try await model.client?.rows(table: "notes", search: "Must not appear").isEmpty == true)
    await model.close()
  }

  @Test func editorRejectsTableSelectionChangesBeforeCallingCore() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let context = try #require(model.editingContext)
    model.table = "history"
    do {
      try await model.save(["title": .string("Must not appear")], original: nil, context: context)
      Issue.record("A stale table selection was accepted")
    } catch let error as WorkspaceError {
      #expect(error.message == "The workspace or table changed. Reopen the record before saving.")
    }
    await model.close()
  }
}
