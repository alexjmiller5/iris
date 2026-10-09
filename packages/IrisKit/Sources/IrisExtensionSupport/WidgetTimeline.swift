import Foundation

public struct WidgetTimeline: Sendable {
  public struct Entry: Sendable {
    public let date: Date
    public let result: WidgetReadResult
  }
  public let entries: [Entry]
  public let refreshAfter: Date

  public static func load(
    store: WidgetPublicationStore, sourceID: String,
    workspaceID: String, replicaID: String, now: Date = Date()
  ) -> Self {
    let current = store.read(
      sourceID: sourceID, workspaceID: workspaceID,
      replicaID: replicaID, now: now)
    var entries = [Entry(date: now, result: current)]
    var refreshAfter = now.addingTimeInterval(900)
    if current.state == .current, let boundary = current.content?.nextBoundary,
      boundary > now, boundary.timeIntervalSince(now) <= 172800
    {
      let next = store.read(
        sourceID: sourceID, workspaceID: workspaceID,
        replicaID: replicaID, now: boundary, saveSuccess: false)
      entries.append(Entry(date: boundary, result: next))
      refreshAfter = boundary
    }
    return Self(entries: entries, refreshAfter: refreshAfter)
  }
}
