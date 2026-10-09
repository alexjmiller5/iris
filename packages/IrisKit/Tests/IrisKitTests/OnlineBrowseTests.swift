import Foundation
import Testing

@testable import IrisKit

@MainActor
struct OnlineBrowseTests {
  @Test func exactIDOutsideLoadedPagePreservesWhitespaceAndAcceptsCoreCollatedIdentity()
    async throws
  {
    var requested: [String] = []
    let model = OnlineBrowseModel(
      table: "notes",
      load: { _ in
        CoreRemoteRowsPage(rows: [row("other")], nextCursor: "more")
      },
      read: { id in
        requested.append(id)
        return CoreRemoteRowResult(
          row: row(" CANONICAL ", title: "Fresh exact match", deleted: true))
      })
    await model.reload()
    await model.open(id: " canonical ")
    #expect(
      requested == [" canonical "], "Opaque IDs must not be trimmed or case-folded by the host")
    #expect(model.selected?.id == " CANONICAL " && model.selected?.deleted == true)
    #expect(model.rows.map(\.id) == ["other"] && model.nextCursor == "more")
  }

  @Test(arguments: ["cancel", "typing", "newer", "context"])
  func exactIDLookupDiscardsSupersededReplies(transition: String) async throws {
    var current = true
    var pending: CheckedContinuation<CoreRemoteRowResult, any Error>?
    let model = OnlineBrowseModel(
      table: "notes", load: { _ in CoreRemoteRowsPage(rows: [], nextCursor: nil) },
      read: { id in
        if id == "old" { return try await withCheckedThrowingContinuation { pending = $0 } }
        return CoreRemoteRowResult(row: row("new"))
      }, isCurrent: { current })
    let first = Task { await model.open(id: "old") }
    // A missing implementation must fail promptly instead of hanging the RED test.
    for _ in 0..<100 where pending == nil { await Task.yield() }
    let receipt = try #require(pending)
    if transition == "cancel" {
      model.cancel()
    } else if transition == "typing" {
      model.recordID = "another ID"
    } else if transition == "context" {
      current = false
    } else {
      await model.open(id: "new")
    }
    receipt.resume(returning: CoreRemoteRowResult(row: row("old")))
    await first.value
    #expect(model.selected?.id == (transition == "newer" ? "new" : nil))
    #expect(model.opening == nil && model.openError == nil)
  }

  private func row(_ id: String, title: String? = nil, deleted: Bool = false) -> CoreRemoteRecord {
    CoreRemoteRecord(
      record: ["id": .string(id), "title": .string(title ?? id)], label: title ?? id,
      deleted: deleted)
  }

  @Test func pagesUseServerCursorReplaceDuplicateRowsAndRetryWithoutDroppingResults() async throws {
    var cursors: [String?] = []
    var fail = true
    let model = OnlineBrowseModel(
      table: "notes",
      load: { cursor in
        cursors.append(cursor)
        switch cursor {
        case nil: return CoreRemoteRowsPage(rows: [row("a"), row("b")], nextCursor: "page-one")
        case "page-one":
          if fail { throw WorkspaceError(message: "Synthetic page failure", violations: []) }
          return CoreRemoteRowsPage(
            rows: [row("b", title: "Updated"), row("c")], nextCursor: "page-two")
        default: return CoreRemoteRowsPage(rows: [], nextCursor: nil)
        }
      }, read: { _ in CoreRemoteRowResult(row: nil) })
    await model.reload()
    await model.reload(more: true)
    #expect(model.rows.map(\.id) == ["a", "b"] && model.error != nil)
    #expect(model.nextCursor == "page-one")
    fail = false
    await model.reload(more: true)
    #expect(model.rows.map(\.id) == ["a", "b", "c"])
    #expect(model.rows[1].label == "Updated")
    #expect(model.nextCursor == "page-two" && model.error == nil)
    await model.reload(more: true)
    #expect(model.nextCursor == nil && model.rows.count == 3)
    #expect(cursors == [nil, "page-one", "page-one", "page-two"])
  }

  @Test(arguments: ["cancel", "context", "newer", "error"])
  func oldPageCannotRestoreDismissedResultsOrReplaceANewerRequest(transition: String) async throws {
    var current = true
    var pending: CheckedContinuation<CoreRemoteRowsPage, any Error>?
    var calls = 0
    let model = OnlineBrowseModel(
      table: "notes",
      load: { _ in
        calls += 1
        if calls == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
        return CoreRemoteRowsPage(rows: [row("new")], nextCursor: nil)
      }, read: { _ in CoreRemoteRowResult(row: nil) }, isCurrent: { current })
    let first = Task { await model.reload() }
    while pending == nil { await Task.yield() }
    if transition == "cancel" {
      model.cancel()
    } else if transition == "context" {
      current = false
    } else {
      await model.reload()
    }
    if transition == "error" {
      pending?.resume(throwing: WorkspaceError(message: "Obsolete", violations: []))
    } else {
      pending?.resume(returning: CoreRemoteRowsPage(rows: [row("old")], nextCursor: "old-cursor"))
    }
    await first.value
    #expect(model.rows.map(\.id) == (["newer", "error"].contains(transition) ? ["new"] : []))
    #expect(model.error == nil && model.nextCursor == nil && !model.loading)
  }

  @Test func openingFetchesCurrentRowAndKeepsMissingAndDeletedStatesExplicit() async throws {
    var receipt = CoreRemoteRowResult(row: nil)
    let model = OnlineBrowseModel(
      table: "notes",
      load: { _ in
        CoreRemoteRowsPage(rows: [row("a", title: "Old list label")], nextCursor: nil)
      },
      read: { id in
        #expect(id == "a")
        return receipt
      })
    await model.reload()
    await model.open(model.rows[0])
    #expect(model.selected == nil && model.openError != nil)
    receipt = CoreRemoteRowResult(row: row("a", title: "Fresh deleted row", deleted: true))
    await model.open(model.rows[0])
    #expect(model.selected?.label == "Fresh deleted row" && model.selected?.deleted == true)
    #expect(model.openError == nil)
    model.cancel()
    #expect(model.rows.isEmpty && model.selected == nil)
  }

  @Test(arguments: ["cancel", "context", "newer", "refresh"])
  func lateOpenCannotNavigateAfterCancellationContextChangeOrAnotherSelection(transition: String)
    async throws
  {
    var current = true
    var pending: CheckedContinuation<CoreRemoteRowResult, any Error>?
    let model = OnlineBrowseModel(
      table: "notes",
      load: { _ in
        CoreRemoteRowsPage(rows: [row("a"), row("b")], nextCursor: nil)
      },
      read: { id in
        if id == "a" { return try await withCheckedThrowingContinuation { pending = $0 } }
        return CoreRemoteRowResult(row: row("b"))
      }, isCurrent: { current })
    await model.reload()
    let first = Task { await model.open(model.rows[0]) }
    while pending == nil { await Task.yield() }
    if transition == "cancel" {
      model.cancel()
    } else if transition == "context" {
      current = false
    } else if transition == "newer" {
      await model.open(model.rows[1])
    } else {
      await model.reload()
    }
    pending?.resume(returning: CoreRemoteRowResult(row: row("a")))
    await first.value
    #expect(model.selected?.id == (transition == "newer" ? "b" : nil))
    #expect(model.openError == nil && model.opening == nil)
  }
}
