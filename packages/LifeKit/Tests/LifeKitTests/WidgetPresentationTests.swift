import Foundation
import Testing

@testable import LifeExtensionSupport

struct WidgetPresentationTests {
  private func result(_ rows: [CoreRow], stale: Bool = false) -> WidgetReadResult {
    WidgetReadResult(
      state: stale ? .stale : .current,
      content: WidgetContent(
        workspaceID: "workspace", replicaID: "replica", sourceID: "source",
        title: "Private source title", rows: rows, dataAsOf: Date(timeIntervalSince1970: 100),
        partial: true, effectiveDay: "2026-10-07", nextBoundary: nil, calendarPolicy: nil))
  }

  @Test func accessoryAndRedactedPresentationContainNoSourceOrRecordTitles() {
    let input = result([["id": .string("one"), "title": .string("Private record title")]])
    for privacy in [WidgetPresentation.Privacy.accessory, .redacted] {
      let view = WidgetPresentation(input, kind: .list, displayColumn: "title", privacy: privacy)
      #expect(view.title == "Records")
      #expect(view.rows.isEmpty)
      #expect(!view.accessibilityLabel.contains("Private"))
      #expect(view.total == nil)
    }
    let count = WidgetPresentation(
      result([["count": .number(13)]]), kind: .count, privacy: .accessory)
    #expect(count.total == "13")
    #expect(!count.accessibilityLabel.contains("Private"))
  }

  @Test func failedCountsNeverAppearAsZeroAndCapRemainsExplicit() {
    let missing = WidgetPresentation(
      WidgetReadResult(state: .unavailable, content: nil), kind: .count)
    #expect(missing.total == nil)
    #expect(missing.notice == "Open the app to refresh")
    let empty = WidgetPresentation(result([["count": .number(0)]]), kind: .count)
    #expect(empty.total == "0")
    let capped = WidgetPresentation(result([["count": .number(10001)]]), kind: .count)
    #expect(capped.total == "10,000+")
    let invalid = WidgetPresentation(result([["count": .number(-1)]]), kind: .count)
    #expect(invalid.total == nil)
    #expect(invalid.notice == "Open the app to refresh")
  }

  @Test func staleEmptyResultAndPartialDataAreNeverPresentedAsCurrentEmpty() {
    let old = WidgetPresentation(result([], stale: true), kind: .list, displayColumn: "title")
    #expect(old.notice == "Stale · Partial data")
    #expect(old.emptyLabel == "Last available list was empty")
    #expect(old.accessibilityLabel.contains("Stale"))
    #expect(old.accessibilityLabel.contains("Partial data"))
    #expect(old.dataAsOf == Date(timeIntervalSince1970: 100))
  }

  @Test func rowsPreserveExactIDsAndPlainTitlesWithinLayoutBudget() {
    let input = result([
      ["id": .string("café"), "title": .string("**plain title**")],
      ["id": .string("cafe\u{301}"), "title": .string("Second")],
      ["id": .string("third"), "title": .null],
      ["id": .string("fourth"), "title": .number(42)],
    ])
    let compact = WidgetPresentation(input, kind: .list, displayColumn: "title", rowLimit: 1)
    #expect(compact.rows.count == 1)
    #expect(compact.rows.first?.title == "**plain title**")
    let expanded = WidgetPresentation(input, kind: .list, displayColumn: "title", rowLimit: 20)
    #expect(Set(expanded.rows.map(\.id)).count == 4)
    #expect(expanded.rows[2].title == "Untitled")
    #expect(expanded.rows.last?.title == "42")
  }
}
