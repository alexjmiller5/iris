import Foundation
import Testing

@testable import IrisKit

@MainActor
struct NativePinsTests {
  private func list(_ names: [String]) -> CoreSidebarPinList {
    CoreSidebarPinList(
      pins: names.enumerated().map { index, name in
        CoreSidebarPin(
          id: "pin:\(name)", tbl: name, position: index,
          updatedAt: "2026-01-01T00:00:00.000Z", deletedAt: nil, unavailable: nil)
      }, unavailable: nil)
  }

  @Test func failedWriteAndReadRetainTheLastAcknowledgedPins() async {
    var failRead = false
    let model = NativePinsModel(
      list: {
        if failRead { throw CocoaError(.fileReadUnknown) }
        return list(["zeta", "alpha"])
      },
      pin: { _ in throw CocoaError(.fileWriteUnknown) },
      unpin: { _ in throw CocoaError(.fileWriteUnknown) },
      move: { _ in throw CocoaError(.fileWriteUnknown) })
    await model.refresh()
    #expect(model.active.map(\.tbl) == ["zeta", "alpha"])
    #expect(await model.unpin("pin:zeta") == false)
    #expect(model.active.map(\.tbl) == ["zeta", "alpha"] && model.error != nil)
    await model.refresh()
    #expect(model.error == nil)
    failRead = true
    await model.refresh()
    #expect(model.active.count == 2 && model.disabled)
  }

  @Test func restoreUsesTombstoneAndMoveUsesCompleteSelectedRevisionSet() async {
    var snapshot = list(["zeta", "alpha"])
    snapshot.pins[1].deletedAt = snapshot.pins[1].updatedAt
    var pinned: CorePinTableArgs?
    var moved: CoreMoveTablePinArgs?
    let model = NativePinsModel(
      list: { snapshot },
      pin: { args in
        pinned = args
        return list(["zeta", "alpha"])
      },
      unpin: { _ in list([]) },
      move: { args in
        moved = args
        return list(["alpha", "zeta"])
      })
    await model.refresh()
    #expect(model.active.count == 1)
    #expect(await model.pin("alpha"))
    #expect(pinned?.expectedUpdatedAt == snapshot.pins[1].updatedAt)
    #expect(await model.move("pin:alpha", direction: "up"))
    #expect(moved?.expected.map(\.id) == ["pin:zeta", "pin:alpha"])
    #expect(model.active.map(\.tbl) == ["alpha", "zeta"])
  }

  @Test func cancelledWorkspaceCannotPublishLateRead() async {
    var pending: CheckedContinuation<CoreSidebarPinList, Never>?
    let model = NativePinsModel(
      list: { await withCheckedContinuation { pending = $0 } },
      pin: { _ in list([]) }, unpin: { _ in list([]) }, move: { _ in list([]) })
    let read = Task { await model.refresh() }
    while pending == nil { await Task.yield() }
    model.cancel()
    pending?.resume(returning: list(["old"]))
    await read.value
    #expect(model.snapshot == nil && model.active.isEmpty && model.disabled)
  }

  @Test func pinningRemovesOnlyExactTargetsFromBothTableGroups() {
    let tables = NativeSidebarTables(
      [
        ["id": .string("notes"), "readOnly": .bool(false)],
        ["id": .string("history"), "readOnly": .bool(true)],
        ["id": .string("topics"), "readOnly": .bool(false)],
      ], pins: list(["history", "notes"]).pins)
    #expect(tables.ordinary.map(\.id) == ["topics"] && tables.system.isEmpty)
  }
}

@MainActor
struct WorkspacePinsTests {
  @Test func actualWorkspacePersistsPinReceiptsAndKeepsTheEditorRecord() async throws {
    let model = WorkspaceModel()
    await model.open(demo: true)
    let pins = try #require(model.pins)
    let workspace = try #require(model.client)
    await pins.refresh()
    #expect(pins.snapshot?.unavailable == nil)
    let before = model.rows
    #expect(await pins.pin("topics"))
    #expect(await pins.pin("notes"))
    #expect(pins.active.map(\.tbl) == ["topics", "notes"])
    #expect(model.rows == before)
    #expect(try await workspace.listSidebarPins() == pins.snapshot)
    let note = try #require(pins.active.last)
    #expect(await pins.move(note.id, direction: "up"))
    #expect(pins.active.map(\.tbl) == ["notes", "topics"])
    #expect(await pins.unpin(note.id))
    #expect(pins.active.map(\.tbl) == ["topics"])
    #expect(await pins.pin("notes"))
    #expect(pins.active.map(\.tbl) == ["topics", "notes"])
    try await workspace.close()
  }

  @Test func acknowledgedPinsSurviveNativeSQLiteFileReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("pins.sqlite").path
    let original = try NativeWorkspace(path: path)
    try await original.createSample()
    let saved = try await original.pinTable(
      CorePinTableArgs(table: "notes", expectedUpdatedAt: nil))
    try await original.close()
    let reopened = try NativeWorkspace(path: path)
    #expect(try await reopened.listSidebarPins() == saved)
    try await reopened.close()
  }
}
