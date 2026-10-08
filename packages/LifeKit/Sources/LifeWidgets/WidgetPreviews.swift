#if os(iOS) && DEBUG
  import Foundation
  import LifeExtensionSupport
  import SwiftUI
  import WidgetKit

  /// Synthetic gallery data only; never a real workspace.
  private func preview(_ kind: CoreReadPlanKind, rows: String, stale: Bool = false) -> WidgetEntry {
    let json = """
      {"workspaceID":"preview","replicaID":"preview","sourceID":"preview","title":"Synthetic daily",
       "rows":\(rows),"dataAsOf":781000000,"partial":false,"effectiveDay":"2026-10-08"}
      """
    let content = try? JSONDecoder().decode(WidgetContent.self, from: Data(json.utf8))
    return WidgetEntry(
      date: Date(), result: WidgetReadResult(state: stale ? .stale : .current, content: content),
      kind: kind, displayColumn: "title",
      openURL: URL(string: "life://open/v1?workspace=local%3Apreview&table=notes"))
  }

  private let titles = """
    [{"id":"a","title":"Plan the week"},{"id":"b","title":"Water the plants"},
     {"id":"c","title":"Call the library"},{"id":"d","title":"Draft the newsletter"},
     {"id":"e","title":"Book a dentist visit"},{"id":"f","title":"Return the parcel"}]
    """

  #Preview("Table small", as: .systemSmall) { LifeTableWidget() } timeline: {
    preview(.list, rows: titles)
  }
  #Preview("Today medium", as: .systemMedium) { LifeTodayWidget() } timeline: {
    preview(.list, rows: titles)
    preview(.list, rows: "[]")
  }
  #Preview("Table large stale", as: .systemLarge) { LifeTableWidget() } timeline: {
    preview(.list, rows: titles, stale: true)
  }
  #Preview("Count small", as: .systemSmall) { LifeCountWidget() } timeline: {
    preview(.count, rows: #"[{"count":10001}]"#)
  }
  #Preview("Lock rectangular", as: .accessoryRectangular) { LifeCountWidget() } timeline: {
    preview(.count, rows: #"[{"count":7}]"#)
  }
  #Preview("Lock circular", as: .accessoryCircular) { LifeCountWidget() } timeline: {
    preview(.count, rows: #"[{"count":7}]"#)
  }
  #Preview("Lock inline", as: .accessoryInline) { LifeCountWidget() } timeline: {
    preview(.count, rows: #"[{"count":7}]"#)
  }
#endif
