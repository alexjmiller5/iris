import Foundation

/// A setting that makes a skipped table download: include it, or raise the row limit to its size.
enum DownloadChoice: Hashable {
  case include
  case limit(Int)
}

extension ReplicaPreferences {
  /// Including the table always works; a higher limit only when the limit alone left it out
  /// (no explicit choice and a known row count over the limit, the core default when unset).
  func downloadChoices(for detail: CoreSkippedTableDetail) -> [DownloadChoice] {
    guard tables[detail.table] == nil, let rows = detail.rows, maxRows.map({ rows > $0 }) ?? true
    else { return [.include] }
    return [.include, .limit(rows)]
  }

  func applying(_ choice: DownloadChoice, to table: String) -> ReplicaPreferences {
    var next = self
    switch choice {
    case .include: next.tables[table] = true
    case .limit(let rows):
      next.maxRows = rows
      next.tables[table] = nil
    }
    return next
  }

  /// The next round downloads it with these settings; it stays skipped until that round completes.
  func willDownload(_ detail: CoreSkippedTableDetail) -> Bool {
    if let choice = tables[detail.table] { return choice }
    guard let rows = detail.rows, let maxRows else { return false }
    return rows <= maxRows
  }
}

enum SkippedTableText {
  static func size(_ detail: CoreSkippedTableDetail) -> String {
    guard let rows = detail.rows else { return "Row count unknown until the next sync" }
    let count = "\(rows.formatted()) \(rows == 1 ? "row" : "rows")"
    guard let bytes = detail.estimatedBytes, bytes > 0 else { return count }
    let size = ByteCountFormatter()
    size.countStyle = .decimal
    return "\(count) · about \(size.string(fromByteCount: Int64(bytes)))"
  }

  static func waiting(_ detail: CoreSkippedTableDetail) -> String? {
    switch detail.waitingEdits {
    case 0: nil
    case 1: "1 earlier edit uploads once it syncs."
    case let count: "\(count) earlier edits upload once it syncs."
    }
  }
}

/// The prompt for a skipped table the user just opened, bound to that workspace.
struct DownloadPromptRequest: Identifiable {
  let id = UUID()
  let detail: CoreSkippedTableDetail
  let choices: [DownloadChoice]
  let context: ReplicaDownloadContext
}
