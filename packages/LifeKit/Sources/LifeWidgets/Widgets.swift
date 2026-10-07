#if os(iOS)
  import AppIntents
  import LifeExtensionSupport
  import SwiftUI
  import WidgetKit

  struct WidgetContentView: View {
    let entry: WidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
      let accessory =
        family == .accessoryCircular || family == .accessoryInline
        || family == .accessoryRectangular
      let presentation = WidgetPresentation(
        entry.result, kind: entry.kind, displayColumn: entry.displayColumn,
        privacy: accessory ? .accessory : redaction.isEmpty ? .home : .redacted,
        rowLimit: textSize.isAccessibilitySize
          ? 2 : family == .systemLarge ? 10 : family == .systemMedium ? 5 : 3)
      if family == .accessoryInline {
        Text("\(presentation.total ?? "Unavailable") records")
          .accessibilityLabel(presentation.accessibilityLabel)
          .widgetURL(entry.openURL)
      } else {
        content(presentation, accessory: accessory)
      }
    }

    private func content(_ presentation: WidgetPresentation, accessory: Bool) -> some View {
      VStack(alignment: .leading, spacing: 6) {
        Text(presentation.title).font(.headline).lineLimit(1)
        if let count = presentation.total {
          Text(count).font(accessory ? .headline : .largeTitle).monospacedDigit()
        }
        ForEach(presentation.rows) { row in
          if family == .systemMedium || family == .systemLarge,
            let url = entry.url(recordID: row.recordID)
          {
            Link(destination: url) { rowTitle(row.title) }
          } else {
            rowTitle(row.title)
          }
        }
        if let empty = presentation.emptyLabel {
          Text(empty).font(.caption).foregroundStyle(.secondary)
        }
        if !presentation.notice.isEmpty {
          Text(presentation.notice).font(.caption).foregroundStyle(.secondary)
        }
        if entry.result.state == .stale, let date = presentation.dataAsOf {
          Text("As of \(date, style: .date)").font(.caption2).foregroundStyle(.secondary)
        }
        if !accessory { Spacer(minLength: 0) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityElement(children: .contain)
      .containerBackground(.fill.tertiary, for: .widget)
      .privacySensitive()
      .widgetURL(entry.openURL)
    }

    private func rowTitle(_ title: String) -> some View {
      Text(title).font(.body).lineLimit(textSize.isAccessibilitySize ? 2 : 1)
    }
  }

  public struct LifeTableWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
      AppIntentConfiguration(
        kind: "LifeTableWidget", intent: TableWidgetConfiguration.self,
        provider: ConfiguredWidgetProvider<TableWidgetConfiguration>()
      ) {
        WidgetContentView(entry: $0)
      }
      .configurationDisplayName("Table titles")
      .description("Titles from an enabled table or saved view.")
      .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
  }

  public struct LifeTodayWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
      AppIntentConfiguration(
        kind: "LifeTodayWidget", intent: TodayWidgetConfiguration.self,
        provider: ConfiguredWidgetProvider<TodayWidgetConfiguration>()
      ) {
        WidgetContentView(entry: $0)
      }
      .configurationDisplayName("Today")
      .description("A daily saved view using its time zone and day boundary.")
      .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
  }

  public struct LifeCountWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
      AppIntentConfiguration(
        kind: "LifeCountWidget", intent: CountWidgetConfiguration.self,
        provider: ConfiguredWidgetProvider<CountWidgetConfiguration>()
      ) {
        WidgetContentView(entry: $0)
      }
      .configurationDisplayName("Record count")
      .description("A bounded record count. Lock Screen widgets show no private titles.")
      .supportedFamilies([
        .systemSmall, .accessoryCircular, .accessoryInline, .accessoryRectangular,
      ])
    }
  }

  public struct LifeQuickAddWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
      AppIntentConfiguration(
        kind: "LifeQuickAddWidget", intent: QuickAddWidgetConfiguration.self,
        provider: QuickAddWidgetProvider()
      ) { entry in
        QuickAddWidgetView(entry: entry)
      }
      .configurationDisplayName("Quick Add")
      .description("Open a recoverable draft. No record is saved until you choose Save.")
      .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
  }

  private struct QuickAddWidgetView: View {
    let entry: QuickAddWidgetEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
      Group {
        if let source = entry.source {
          Button(intent: QuickAddIntent(source: source)) {
            VStack(spacing: 6) {
              Label("Quick Add", systemImage: "plus").font(.headline)
              if family == .systemSmall { Text(source.title).font(.body).lineLimit(2) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
          }.accessibilityLabel("Quick Add").privacySensitive()
        } else {
          Label("Configure in app", systemImage: "plus").font(.caption)
        }
      }.containerBackground(.fill.tertiary, for: .widget)
    }
  }

  @available(iOS 18.0, *)
  public struct QuickAddControlConfiguration: ControlConfigurationIntent {
    public static let title: LocalizedStringResource = "Quick Add"
    @Parameter(title: "Writable table", query: QuickAddSourceQuery()) public var source:
      WidgetSourceEntity
    public init() {}
  }

  @available(iOS 18.0, *)
  public struct LifeQuickAddControl: ControlWidget {
    public init() {}
    public var body: some ControlWidgetConfiguration {
      AppIntentControlConfiguration(
        kind: "LifeQuickAddControl", intent: QuickAddControlConfiguration.self
      ) { configuration in
        ControlWidgetButton(action: QuickAddIntent(source: configuration.source)) {
          Label("Quick Add", systemImage: "plus")
        }
      }
      .displayName("Quick Add")
      .description("Prepare a draft after unlocking. Save explicitly in Life UI.")
    }
  }
#endif
