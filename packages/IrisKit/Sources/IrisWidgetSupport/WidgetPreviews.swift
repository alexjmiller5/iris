#if os(iOS) && DEBUG
  import Foundation
  import IrisExtensionSupport
  import SwiftUI
  import WidgetKit

  /// Synthetic gallery data only; never a real workspace.
  private func syntheticEntry(_ kind: CoreReadPlanKind, rows: String, stale: Bool = false) -> WidgetEntry {
    let json = """
      {"workspaceID":"preview","replicaID":"preview","sourceID":"preview","title":"Synthetic daily",
       "rows":\(rows),"dataAsOf":781000000,"partial":false,"effectiveDay":"2026-10-08"}
      """
    let content = try? JSONDecoder().decode(WidgetContent.self, from: Data(json.utf8))
    return WidgetEntry(
      date: Date(), result: WidgetReadResult(state: stale ? .stale : .current, content: content),
      kind: kind, displayColumn: "title",
      openURL: URL(string: "iris://open/v1?workspace=local%3Apreview&table=notes"))
  }

  private let titles = """
    [{"id":"a","title":"Plan the week"},{"id":"b","title":"Water the plants"},
     {"id":"c","title":"Call the library"},{"id":"d","title":"Draft the newsletter"},
     {"id":"e","title":"Book a dentist visit"},{"id":"f","title":"Return the parcel"}]
    """

  #Preview("Table small", as: .systemSmall) { IrisTableWidget() } timeline: {
    syntheticEntry(.list, rows: titles)
  }
  #Preview("Today medium", as: .systemMedium) { IrisTodayWidget() } timeline: {
    syntheticEntry(.list, rows: titles)
    syntheticEntry(.list, rows: "[]")
  }
  #Preview("Table large stale", as: .systemLarge) { IrisTableWidget() } timeline: {
    syntheticEntry(.list, rows: titles, stale: true)
  }
  #Preview("Count small", as: .systemSmall) { IrisCountWidget() } timeline: {
    syntheticEntry(.count, rows: #"[{"count":10001}]"#)
  }
  #Preview("Lock rectangular", as: .accessoryRectangular) { IrisCountWidget() } timeline: {
    syntheticEntry(.count, rows: #"[{"count":7}]"#)
  }
  #Preview("Lock circular", as: .accessoryCircular) { IrisCountWidget() } timeline: {
    syntheticEntry(.count, rows: #"[{"count":7}]"#)
  }
  #Preview("Lock inline", as: .accessoryInline) { IrisCountWidget() } timeline: {
    syntheticEntry(.count, rows: #"[{"count":7}]"#)
  }
#endif
