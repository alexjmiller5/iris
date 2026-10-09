import Foundation
import IrisExtensionSupport
import WidgetKit

public struct WidgetEntry: TimelineEntry, Sendable {
  public let date: Date
  public let result: WidgetReadResult
  public let kind: CoreReadPlanKind
  public let displayColumn: String?
  public let openURL: URL?

  public func url(recordID: String) -> URL? {
    guard !recordID.isEmpty, var parts = Self.linkComponents(openURL),
      let items = parts.queryItems, !items.contains(where: { $0.name == "row" })
    else { return nil }
    parts.queryItems = items + [URLQueryItem(name: "row", value: recordID)]
    return parts.url
  }

  private static func linkComponents(_ url: URL?) -> URLComponents? {
    guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "iris", parts.host == "open", parts.path == "/v1",
      parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil
    else { return nil }
    return parts
  }

  public static func timeline(
    sourceID: String?, kind: CoreReadPlanKind = .list, calendarOnly: Bool = false,
    library: WidgetLibrary? = .installed(), now: Date = Date()
  ) -> Timeline<Self> {
    let unavailable = Self(
      date: now, result: WidgetReadResult(state: .unavailable, content: nil),
      kind: kind, displayColumn: nil, openURL: nil)
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
      Self(date: $0.date, result: $0.result, kind: kind, displayColumn: source.displayColumn,
        openURL: Self.linkComponents(source.openURL)?.url)
    }, policy: .after(timeline.refreshAfter))
  }
}
