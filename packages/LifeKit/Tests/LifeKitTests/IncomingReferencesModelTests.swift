import Foundation
import Testing

@testable import LifeKit

@MainActor
struct IncomingReferencesModelTests {
  @MainActor private final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
  }

  private let source = CoreReferenceSource(
    table: "notes", column: "topic", label: "Topic", type: "ref", incomplete: false)
  private func row(_ id: String, _ label: String) -> WorkspaceRow {
    WorkspaceRow(record: ["id": .string(id), "body": .string("Full " + label)], label: label)
  }
  private func make(
    sources: (@MainActor (CoreReferenceSourcesArgs) async throws -> [CoreReferenceSource])? = nil,
    current: @escaping @MainActor () -> Bool = { true },
    page: @escaping @MainActor (CoreReferencedByArgs) async throws -> CoreReferencedByPage
  ) -> IncomingReferencesModel {
    IncomingReferencesModel(
      table: "topics", rowID: "target",
      readSources: sources ?? { args in
        #expect(args.table == "topics")
        return [source]
      }, readPage: page, isCurrent: current)
  }

  @Test func discoveryDoesNotReadRowsAndOpeningOneGroupOnlyLoadsOnce() async throws {
    var calls = 0
    let model = make { args in
      #expect(
        args
          == CoreReferencedByArgs(
            table: "topics", rowId: "target", sourceTable: "notes", column: "topic", limit: 20,
            offset: 0))
      calls += 1
      return CoreReferencedByPage(source: source, rows: [row("one", "First")], nextOffset: nil)
    }
    await model.refresh()
    #expect(calls == 0)
    let group = try #require(model.groups.first)
    #expect(group.source == source && group.rows.isEmpty && !group.loaded)
    await model.load(group.id, more: true)
    #expect(calls == 0, "More cannot skip the initial page")
    await model.load(group.id)
    await model.load(group.id)
    await model.load(group.id, more: true)
    #expect(calls == 1)
    #expect(model.groups.first?.rows.first?.label == "First")
    #expect(model.groups.first?.rows.first?.record["body"] == .string("Full First"))
    #expect(model.groups.first?.loaded == true)
  }

  @Test func pagesUseReturnedOffsetDeduplicateIDsAndRefreshSourceMetadata() async throws {
    var offsets: [CoreCount?] = []
    let model = make { args in
      offsets.append(args.offset)
      #expect(args.limit == 20)
      var metadata = source
      metadata.incomplete = args.offset == 37
      metadata.label = args.offset == 37 ? "Renamed" : "Topic"
      return CoreReferencedByPage(
        source: metadata,
        rows: args.offset == 37
          ? [row("one", "Fresh"), row("two", "Second"), row("two", "Newest")]
          : [row("one", "First"), row("one", "Updated")],
        nextOffset: args.offset == 37 ? nil : 37)
    }
    await model.refresh()
    let id = try #require(model.groups.first?.id)
    await model.load(id)
    #expect(model.groups.first?.rows.map(\.label) == ["Updated"])
    await model.load(id, more: true)
    await model.load(id, more: true)
    #expect(offsets == [0, 37])
    #expect(model.groups.first?.rows.map(\.id) == ["one", "two"])
    #expect(model.groups.first?.rows.map(\.label) == ["Fresh", "Newest"])
    #expect(model.groups.first?.source.incomplete == true)
    #expect(model.groups.first?.source.label == "Renamed")
    #expect(model.groups.first?.nextOffset == nil)
  }

  @Test(arguments: [false, true])
  func opaqueIDsStayDistinctWithinAndAcrossPages(_ split: Bool) async throws {
    let composed = "\u{00E9}"
    let decomposed = "e\u{0301}"
    let model = make { args in
      let rows =
        args.offset == 37
        ? [row(decomposed, "Second"), row(composed, "Updated first")]
        : split
          ? [row(composed, "First")]
          : [row(composed, "First"), row(decomposed, "Second")]
      return CoreReferencedByPage(
        source: source, rows: rows, nextOffset: args.offset == 37 ? nil : 37)
    }
    await model.refresh()
    let id = try #require(model.groups.first?.id)
    await model.load(id)
    #expect(model.groups.first?.rows.count == (split ? 1 : 2))
    await model.load(id, more: true)
    let rows = try #require(model.groups.first?.rows)
    #expect(rows.map { Data($0.id.utf8) } == [Data(composed.utf8), Data(decomposed.utf8)])
    #expect(rows.map(\.label) == ["Updated first", "Second"])
  }

  @Test func failedPagesKeepRowsAndOffsetUntilAnExplicitRetry() async throws {
    var fail = true
    var calls = 0
    let model = make { args in
      calls += 1
      if args.offset == 37 && fail {
        throw WorkspaceError(message: "Page unavailable", violations: [])
      }
      return CoreReferencedByPage(
        source: source, rows: [row(args.offset == 37 ? "two" : "one", "Stored")],
        nextOffset: args.offset == 37 ? nil : 37)
    }
    await model.refresh()
    let id = try #require(model.groups.first?.id)
    await model.load(id)
    await model.load(id, more: true)
    #expect(calls == 2)
    #expect(model.groups.first?.rows.map(\.id) == ["one"])
    #expect(model.groups.first?.nextOffset == 37)
    #expect(model.groups.first?.error == "Page unavailable")
    #expect(model.groups.first?.loading == false)
    fail = false
    await model.load(id, more: true)
    #expect(calls == 3)
    #expect(model.groups.first?.rows.map(\.id) == ["one", "two"])
    #expect(model.groups.first?.error == nil)
  }

  @Test func discoveryAndFirstPageFailuresRetryWithoutHidingOtherColumns() async throws {
    let metadataFails = Flag(true)
    var pageFails = true
    let other = CoreReferenceSource(
      table: "notes", column: "related", label: "Related", type: "multi_ref", incomplete: true)
    let model = make(sources: { _ in
      if metadataFails.value {
        throw WorkspaceError(message: "Discovery unavailable", violations: [])
      }
      return [source, other]
    }) { args in
      if args.column == "topic" && pageFails {
        throw WorkspaceError(message: "Group unavailable", violations: [])
      }
      return CoreReferencedByPage(
        source: args.column == "topic" ? source : other,
        rows: [row(args.column, "Stored")], nextOffset: nil)
    }
    await model.refresh()
    #expect(model.error == "Discovery unavailable" && !model.loading)
    metadataFails.value = false
    await model.refresh()
    #expect(model.error == nil && model.groups.count == 2)
    let first = try #require(model.groups.first?.id)
    let second = try #require(model.groups.last?.id)
    #expect(first != second)
    await model.load(first)
    await model.load(second)
    #expect(model.groups[0].error == "Group unavailable" && !model.groups[0].loaded)
    #expect(model.groups[1].rows.map(\.id) == ["related"])
    #expect(model.groups[1].source.incomplete)
    pageFails = false
    await model.load(first)
    #expect(model.groups[0].rows.map(\.id) == ["topic"] && model.groups[0].error == nil)
  }

  @Test func simultaneousOpenRequestsDoNotReadTheSamePageTwice() async throws {
    var held: CheckedContinuation<CoreReferencedByPage, any Error>?
    var calls = 0
    let model = make { _ in
      calls += 1
      if calls > 1 {
        Issue.record("The pending page was requested twice")
        return CoreReferencedByPage(source: source, rows: [], nextOffset: nil)
      }
      return try await withCheckedThrowingContinuation { held = $0 }
    }
    await model.refresh()
    let id = try #require(model.groups.first?.id)
    let pending = Task { await model.load(id) }
    while held == nil { await Task.yield() }
    await model.load(id)
    #expect(calls == 1 && model.groups.first?.loading == true)
    held?.resume(returning: CoreReferencedByPage(source: source, rows: [], nextOffset: nil))
    await pending.value
    #expect(model.groups.first?.loaded == true && model.groups.first?.loading == false)
  }

  @Test(arguments: ["refresh", "dispose", "context", "cancel"], [false, true])
  func staleMetadataCannotPublishAfterHostTransitions(_ transition: String, fails: Bool) async {
    var held: CheckedContinuation<[CoreReferenceSource], any Error>?
    let current = Flag(true)
    var calls = 0
    let model = make(
      sources: { _ in
        calls += 1
        if calls == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
        return []
      }, current: { current.value }
    ) { _ in
      Issue.record("Discovery must not read rows")
      return CoreReferencedByPage(source: source, rows: [], nextOffset: nil)
    }
    let pending = Task { await model.refresh() }
    while held == nil { await Task.yield() }
    switch transition {
    case "refresh": await model.refresh()
    case "dispose": model.dispose()
    case "context": current.value = false
    default: pending.cancel()
    }
    if fails {
      held?.resume(throwing: WorkspaceError(message: "Obsolete metadata", violations: []))
    } else {
      held?.resume(returning: [source])
    }
    await pending.value
    #expect(model.groups.isEmpty && model.error == nil && !model.loading)
    if transition == "dispose" || transition == "context" {
      let before = calls
      await model.refresh()
      #expect(calls == before)
    }
  }

  @Test(arguments: ["refresh", "dispose", "context", "cancel"], [false, true])
  func stalePagesCannotPublishAfterHostTransitions(_ transition: String, fails: Bool) async throws {
    var held: CheckedContinuation<CoreReferencedByPage, any Error>?
    let current = Flag(true)
    var calls = 0
    let model = make(current: { current.value }) { _ in
      calls += 1
      if calls > 1 {
        throw WorkspaceError(message: "Read after the panel became obsolete", violations: [])
      }
      return try await withCheckedThrowingContinuation { held = $0 }
    }
    await model.refresh()
    let id = try #require(model.groups.first?.id)
    let pending = Task { await model.load(id) }
    while held == nil { await Task.yield() }
    switch transition {
    case "refresh": await model.refresh()
    case "dispose": model.dispose()
    case "context": current.value = false
    default: pending.cancel()
    }
    if fails {
      held?.resume(throwing: WorkspaceError(message: "Obsolete page", violations: []))
    } else {
      held?.resume(
        returning: CoreReferencedByPage(source: source, rows: [row("late", "Old")], nextOffset: 20))
    }
    await pending.value
    #expect(model.groups.first?.rows.isEmpty == true)
    #expect(model.groups.first?.error == nil)
    #expect(model.groups.first?.loaded == false && model.groups.first?.loading == false)
    if transition == "dispose" || transition == "context" {
      await model.load(id)
      #expect(calls == 1)
    }
  }
}
