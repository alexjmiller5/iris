import Foundation
import Testing

@testable import IrisKit

@MainActor
struct RejectionInboxModelTests {
  private func status(_ count: Int = 205) -> CoreSyncStatus {
    CoreSyncStatus(lastSuccessfulSync: nil, pendingUiEdits: 0, rejected: count, skippedTables: [])
  }
  private func entry(_ id: String, table: String = "items", message: String = "Rejected")
    -> CoreRejectedEdit
  {
    CoreRejectedEdit(
      table: table, rowID: id, submitted: ["id": .string(id)],
      errors: [["id": .string(id), "message": .string(message)]])
  }

  @Test func totalIsIndependentOfLoadedPagesAndTerminalDoesNotRefetch() async {
    var offsets: [Int?] = []
    let model = RejectionInboxModel(
      readStatus: { status() },
      readPage: { args in
        #expect(args.limit == 100)
        offsets.append(args.offset)
        return CoreRejectionsPage(
          rejections: [entry(String(args.offset ?? -1))],
          nextOffset: args.offset == 200 ? nil : (args.offset ?? 0) + 100)
      })
    await model.refresh()
    #expect(model.total == 205 && model.entries.count == 1 && model.nextOffset == 100)
    await model.loadMore()
    await model.loadMore()
    await model.loadMore()
    #expect(offsets == [0, 100, 200])
    #expect(model.total == 205 && model.entries.count == 3 && model.nextOffset == nil)
  }

  @Test func statusFailureIsVisibleAndDoesNotGuessZeroOrReadPages() async {
    var fail = true
    var pages = 0
    let model = RejectionInboxModel(
      readStatus: {
        if fail { throw WorkspaceError(message: "Status unavailable", violations: []) }
        return status(1)
      },
      readPage: { _ in
        pages += 1
        return CoreRejectionsPage(rejections: [entry("one")], nextOffset: nil)
      })
    await model.refresh()
    #expect(model.total == nil && model.error == "Status unavailable" && !model.loading)
    await model.loadMore()
    #expect(pages == 0)
    fail = false
    await model.refresh()
    #expect(model.total == 1 && model.entries.count == 1 && model.error == nil && pages == 1)
  }

  @Test(arguments: [0, 100])
  func failedPageRetainsEntriesTotalAndExactRetryOffset(_ failingOffset: Int) async {
    var fail = true
    var offsets: [Int?] = []
    let model = RejectionInboxModel(
      readStatus: { status() },
      readPage: { args in
        offsets.append(args.offset)
        if args.offset == failingOffset && fail {
          throw WorkspaceError(message: "Page unavailable", violations: [])
        }
        return CoreRejectionsPage(
          rejections: [entry(String(args.offset ?? -1))],
          nextOffset: args.offset == 0 ? 100 : nil)
      })
    await model.refresh()
    if failingOffset == 100 { await model.loadMore() }
    #expect(model.total == 205 && model.error == "Page unavailable" && !model.loading)
    #expect(
      model.nextOffset == failingOffset && model.entries.count == (failingOffset == 0 ? 0 : 1))
    fail = false
    await model.loadMore()
    #expect(offsets.suffix(2) == [failingOffset, failingOffset])
    #expect(model.error == nil && model.entries.count == (failingOffset == 0 ? 1 : 2))
  }

  @Test func dedupeUsesExactTableAndRowBytesAndPreservesOpaqueCoreOffset() async {
    let composed = "\u{e9}"
    let decomposed = "e\u{301}"
    var offsets: [Int?] = []
    let model = RejectionInboxModel(
      readStatus: { status(3) },
      readPage: { args in
        offsets.append(args.offset)
        return CoreRejectionsPage(
          rejections: args.offset == 0
            ? [entry(composed), entry(decomposed)]
            : [entry(composed, message: "New error"), entry(composed, table: "other")],
          nextOffset: args.offset == 0 ? 37 : nil)
      })
    await model.refresh()
    #expect(Set(model.entries.map(\.inboxID)).count == 2)
    await model.loadMore()
    #expect(offsets == [0, 37] && model.entries.count == 3)
    #expect(Set(model.entries.map(\.inboxID)).count == 3)
    #expect(
      model.entries.map { Data($0.rowID.utf8) } == [
        Data(composed.utf8), Data(decomposed.utf8), Data(composed.utf8),
      ])
    #expect(model.entries.first?.errors.first?["message"] == .string("New error"))
  }

  @Test func simultaneousLoadMoreRequestsOnlyOnePage() async throws {
    var held: CheckedContinuation<CoreRejectionsPage, any Error>?
    var calls = 0
    let model = RejectionInboxModel(
      readStatus: { status() },
      readPage: { args in
        calls += 1
        if args.offset == 0 {
          return CoreRejectionsPage(rejections: [entry("first")], nextOffset: 100)
        }
        if calls > 2 { throw WorkspaceError(message: "Duplicate request", violations: []) }
        return try await withCheckedThrowingContinuation { held = $0 }
      })
    await model.refresh()
    let pending = Task { await model.loadMore() }
    for _ in 0..<1000 where held == nil { await Task.yield() }
    let continuation = try #require(held)
    await model.loadMore()
    #expect(calls == 2 && model.loading)
    continuation.resume(
      returning: CoreRejectionsPage(rejections: [entry("second")], nextOffset: nil))
    await pending.value
    #expect(model.entries.count == 2 && !model.loading)
  }

  @Test(arguments: ["refresh", "dispose", "context", "cancel"], [false, true])
  func staleStatusCannotPublish(_ transition: String, fails: Bool) async throws {
    var held: CheckedContinuation<CoreSyncStatus, any Error>?
    var current = true
    var calls = 0
    var pages = 0
    let model = RejectionInboxModel(
      readStatus: {
        calls += 1
        if calls == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
        return status(1)
      },
      readPage: { _ in
        pages += 1
        return CoreRejectionsPage(rejections: [entry("new")], nextOffset: nil)
      }, isCurrent: { current })
    let pending = Task { await model.refresh() }
    for _ in 0..<1000 where held == nil { await Task.yield() }
    let continuation = try #require(held)
    switch transition {
    case "refresh": await model.refresh()
    case "dispose": model.dispose()
    case "context": current = false
    default: pending.cancel()
    }
    if fails {
      continuation.resume(throwing: WorkspaceError(message: "Stale status", violations: []))
    } else {
      continuation.resume(returning: status(9))
    }
    await pending.value
    #expect(model.error == nil && !model.loading)
    #expect(model.total == (transition == "refresh" ? 1 : nil))
    #expect(pages == (transition == "refresh" ? 1 : 0))
    if transition == "dispose" || transition == "context" {
      await model.refresh()
      #expect(calls == 1)
    }
  }

  @Test(arguments: ["refresh", "dispose", "context", "cancel"], [false, true])
  func stalePageCannotPublish(_ transition: String, fails: Bool) async throws {
    var held: CheckedContinuation<CoreRejectionsPage, any Error>?
    var current = true
    var calls = 0
    let model = RejectionInboxModel(
      readStatus: { status() },
      readPage: { _ in
        calls += 1
        if calls == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
        return CoreRejectionsPage(rejections: [entry("new")], nextOffset: nil)
      }, isCurrent: { current })
    let pending = Task { await model.refresh() }
    for _ in 0..<1000 where held == nil { await Task.yield() }
    let continuation = try #require(held)
    switch transition {
    case "refresh": await model.refresh()
    case "dispose": model.dispose()
    case "context": current = false
    default: pending.cancel()
    }
    if fails {
      continuation.resume(throwing: WorkspaceError(message: "Stale page", violations: []))
    } else {
      continuation.resume(
        returning: CoreRejectionsPage(rejections: [entry("stale")], nextOffset: 100))
    }
    await pending.value
    #expect(model.error == nil && !model.loading)
    #expect(model.entries.map(\.rowID) == (transition == "refresh" ? ["new"] : []))
    if transition == "dispose" || transition == "context" {
      await model.loadMore()
      await model.refresh()
      #expect(calls == 1)
    }
  }
}
