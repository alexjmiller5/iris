import Foundation
import LifeExtensionSupport
import WidgetKit

public struct WidgetEntry: TimelineEntry, Sendable {
  public let date: Date
  public let result: WidgetReadResult
  public let kind: CoreReadPlanKind
  public let displayColumn: String?

  public static func timeline(
    sourceID: String?, kind: CoreReadPlanKind = .list, calendarOnly: Bool = false,
    library: WidgetLibrary? = .installed(), now: Date = Date()
  ) -> Timeline<Self> {
    let unavailable = Self(
      date: now, result: WidgetReadResult(state: .unavailable, content: nil),
      kind: kind, displayColumn: nil)
    guard let library, let sourceID,
      let sources = try? library.sources(),
      let selected = sources.first(where: {
        Data($0.id.utf8) == Data(sourceID.utf8) && $0.kind == .list
          && (!calendarOnly || $0.usesCalendar)
      }),
      let source = sources.first(where: {
        $0.id == WidgetLibrary.sourceID(
          workspaceID: selected.workspaceID, table: selected.table,
          viewID: selected.viewID, kind: kind)
      })
    else {
      return Timeline(entries: [unavailable], policy: .after(now.addingTimeInterval(900)))
    }
    let timeline = WidgetTimeline.load(
      store: library.store(workspaceID: source.workspaceID), sourceID: source.id,
      workspaceID: source.workspaceID, replicaID: source.replicaID, now: now)
    return Timeline(entries: timeline.entries.map {
      Self(date: $0.date, result: $0.result, kind: kind, displayColumn: source.displayColumn)
    }, policy: .after(timeline.refreshAfter))
  }
}
