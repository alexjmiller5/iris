import AppIntents
import Foundation
import LifeExtensionSupport
import WidgetKit

public protocol WidgetSourceConfiguration: WidgetConfigurationIntent {
  var source: WidgetSourceEntity? { get }
  static var resultKind: CoreReadPlanKind { get }
  static var calendarOnly: Bool { get }
}

public struct TableWidgetConfiguration: WidgetSourceConfiguration {
  public static let title: LocalizedStringResource = "Table titles"
  public static let resultKind: CoreReadPlanKind = .list
  public static let calendarOnly = false
  @Parameter(title: "Table or saved view") public var source: WidgetSourceEntity?
  public init() {}
}

public struct TodayWidgetConfiguration: WidgetSourceConfiguration {
  public static let title: LocalizedStringResource = "Today"
  public static let resultKind: CoreReadPlanKind = .list
  public static let calendarOnly = true
  @Parameter(title: "Daily saved view", query: CalendarWidgetSourceQuery())
  public var source: WidgetSourceEntity?
  public init() {}
}

public struct CountWidgetConfiguration: WidgetSourceConfiguration {
  public static let title: LocalizedStringResource = "Record count"
  public static let resultKind: CoreReadPlanKind = .count
  public static let calendarOnly = false
  @Parameter(title: "Table or saved view") public var source: WidgetSourceEntity?
  public init() {}
}

public struct ConfiguredWidgetProvider<Configuration: WidgetSourceConfiguration>: AppIntentTimelineProvider {
  public init() {}
  public func placeholder(in context: Context) -> WidgetEntry {
    WidgetEntry.timeline(sourceID: nil, kind: Configuration.resultKind, library: nil).entries[0]
  }
  public func snapshot(for configuration: Configuration, in context: Context) async -> WidgetEntry {
    await timeline(for: configuration, in: context).entries[0]
  }
  public func timeline(for configuration: Configuration, in context: Context) async -> Timeline<WidgetEntry> {
    let sourceID = configuration.source?.id
    return WidgetEntry.timeline(
      sourceID: sourceID, kind: Configuration.resultKind,
      calendarOnly: Configuration.calendarOnly)
  }
}
