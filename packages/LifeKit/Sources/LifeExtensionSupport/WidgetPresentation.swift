import Foundation

/// The same privacy-filtered fields feed visible text and accessibility labels.
public struct WidgetPresentation: Sendable {
  public enum Privacy: Sendable { case home, accessory, redacted }
  public struct Row: Identifiable, Sendable {
    public let recordID: String
    public let title: String
    public var id: Data { Data(recordID.utf8) }
  }
  public private(set) var title = "Records"
  public private(set) var rows: [Row] = []
  public private(set) var total: String?
  public private(set) var notice = "Open the app to refresh"
  public private(set) var emptyLabel: String?
  public private(set) var dataAsOf: Date?
  public private(set) var effectiveDay: String?
  public var accessibilityLabel: String {
    ([title] + (total.map { [$0 + " records"] } ?? []) + rows.map(\.title)
      + (emptyLabel.map { [$0] } ?? []) + [notice]).filter { !$0.isEmpty }.joined(separator: ", ")
  }

  public init(
    _ result: WidgetReadResult, kind: CoreReadPlanKind, displayColumn: String? = nil,
    privacy: Privacy = .home, rowLimit: Int = 6
  ) {
    guard result.state != .unavailable, let content = result.content else { return }
    var total: String?
    var rows: [Row] = []
    if kind == .count {
      guard content.rows.count == 1, case .number(let number) = content.rows[0]["count"],
        number.isFinite, number.rounded() == number, number >= 0, number <= 10001
      else { return }
      total = number > 10000 ? "10,000+" : String(Int(number))
    } else {
      guard
        content.rows.allSatisfy({
          if case .string(let id) = $0["id"] { return !id.isEmpty }
          return false
        })
      else { return }
      if privacy == .home {
        rows = content.rows.prefix(max(0, min(20, rowLimit))).compactMap { record in
          guard case .string(let id) = record["id"] else { return nil }
          let text: String
          switch displayColumn.flatMap({ record[$0] }) {
          case .string(let value) where !value.isEmpty: text = String(value.prefix(512))
          case .number(let value) where value.isFinite:
            text =
              value.rounded() == value && abs(value) <= 9_007_199_254_740_991
              ? String(Int64(value)) : String(value)
          default: text = "Untitled"
          }
          return Row(recordID: id, title: text)
        }
      }
    }
    title = privacy == .home ? String(content.title.prefix(512)) : "Records"
    self.total = total
    self.rows = rows
    dataAsOf = content.dataAsOf
    effectiveDay = content.effectiveDay
    notice = [result.state == .stale ? "Stale" : nil, content.partial ? "Partial data" : nil]
      .compactMap { $0 }.joined(separator: " · ")
    if kind == .list, content.rows.isEmpty, privacy == .home {
      emptyLabel = result.state == .stale ? "Last available list was empty" : "No matching records"
    }
  }
}
