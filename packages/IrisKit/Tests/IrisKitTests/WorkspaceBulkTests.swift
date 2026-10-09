import Foundation
import Testing

@testable import IrisKit

@MainActor
struct WorkspaceBulkTests {
  @Test func committedBulkWritesRefreshWorkspaceWithoutStoppingTheirOwnBatch() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let workspace = try #require(model.client)
    _ = try await workspace.write(table: "notes", patch: ["title": .string("Second synthetic row")])
    await model.reload()
    let ids = model.rows.map(\.id)
    let capture = try model.captureLoadedRowsForExport(at: Date())
    let batch = try model.prepareBulkRows(ids: ids)
    await batch.start(values: ["title": .string("Changed")])?.value
    #expect(batch.results.map(\.status) == [.succeeded, .succeeded])
    #expect(model.rows.allSatisfy { $0.record["title"] == .string("Changed") })
    #expect(model.canExportLoadedRows && model.undoAction != nil)
    #expect(capture.rows.allSatisfy { $0["title"] != .string("Changed") })
    await model.close()
  }

  @Test func selectionNotLoadedOrStaleQueryCannotAdmitWrites() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let ids = model.rows.map(\.id)
    #expect(throws: WorkspaceError.self) { try model.prepareBulkRows(ids: ["not-loaded"]) }
    let batch = try model.prepareBulkRows(ids: ids)
    model.search = "different query"
    await batch.start(values: ["title": .string("Must not write")])?.value
    #expect(batch.results.allSatisfy { $0.status == .unattempted })
    #expect(throws: WorkspaceError.self) { try model.prepareBulkRows(ids: ids) }
    let workspace = try #require(model.client)
    let rows = try await workspace.rows(view: CoreView(table: "notes"))
    #expect(rows.allSatisfy { $0.record["title"] != .string("Must not write") })
    await model.close()
  }

  @Test func changedCatalogOrClosedWorkspaceStopsPreparedSelection() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let batch = try model.prepareBulkRows(ids: model.rows.map(\.id))
    model.catalog = nil
    await batch.start(values: ["title": .string("Must not write")])?.value
    #expect(batch.results.allSatisfy { $0.status == .unattempted })
    await model.close()
    await batch.start(values: ["title": .string("Still must not write")])?.value
    #expect(batch.results.allSatisfy { $0.status == .unattempted })
  }
}
