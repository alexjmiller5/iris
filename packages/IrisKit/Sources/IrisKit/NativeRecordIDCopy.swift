import Foundation

enum NativeRecordIDCopy {
  static func text(_ ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    var seen = Set<Data>()
    return ids.filter { seen.insert(Data($0.utf8)).inserted }.joined(separator: "\n")
  }
}
