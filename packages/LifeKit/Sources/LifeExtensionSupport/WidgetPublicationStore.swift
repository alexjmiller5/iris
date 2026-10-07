import CryptoKit
import Darwin
import Foundation

public struct WidgetSource: Codable, Sendable {
  public let id: String
  public let title: String
  public let plan: CoreReadPlan
  public let openURL: URL?
  public init(id: String, title: String, plan: CoreReadPlan, openURL: URL? = nil) {
    self.id = id
    self.title = title
    self.plan = plan
    self.openURL = openURL
  }
}

public struct WidgetPublication: Codable, Sendable {
  public let version: Int
  public let generation: String
  public let accessGeneration: String
  public let workspaceID: String
  public let replicaID: String
  public let dataAsOf: Date
  public let partial: Bool
  public let sources: [WidgetSource]
  public let databaseSHA256: String
}

public struct WidgetContent: Codable, Sendable {
  public let workspaceID: String
  public let replicaID: String
  public let sourceID: String
  public let title: String
  public let rows: [CoreRow]
  public let dataAsOf: Date
  public let partial: Bool
  public let effectiveDay: String?
  public let nextBoundary: Date?
  public let calendarPolicy: CoreReadPlanCalendarPolicy?
}

public struct WidgetReadResult: Sendable {
  public enum State: Sendable { case current, stale, unavailable }
  public let state: State
  public let content: WidgetContent?
  public init(state: State, content: WidgetContent?) {
    self.state = state
    self.content = content
  }
}

/// Capture before any asynchronous preparation. Only this store can issue one.
public struct WidgetPublicationPermit: Codable, Sendable {
  fileprivate let root: URL
  fileprivate let generation: String
}

/// Regenerable app-group state. Shared file locks protect readers across processes;
/// an exclusive commit only swaps a completed generation and reclaims unheld ones.
/// No disk state is written by a timeline read except its bounded display fallback.
public struct WidgetPublicationStore: Sendable {
  public let root: URL
  public init(root: URL) { self.root = root }
  private var pointer: URL { root.appendingPathComponent("current.json") }
  private var fallback: URL { root.appendingPathComponent("fallback", isDirectory: true) }
  private struct Pointer: Codable { let generation: String }

  public func beginPublication() throws -> WidgetPublicationPermit {
    try privateDirectory(root)
    try privateDirectory(fallback)
    return try withLock(exclusive: true) {
      WidgetPublicationPermit(root: root.standardizedFileURL, generation: try revocationToken())
    }
  }

  public func isCurrent(_ permit: WidgetPublicationPermit) -> Bool {
    (try? withLock(exclusive: false) {
      guard permit.root == root.standardizedFileURL else { return false }
      return bytesEqual(permit.generation, try revocationToken())
    }) ?? false
  }

  public func recordRefreshFailure() throws {
    try withLock(exclusive: true) {
      let current: Pointer = try decode(pointer, limit: 4096)
      try write(current, to: root.appendingPathComponent("refresh-failed.json"), limit: 4096)
    }
  }

  public func publish(
    workspaceID: String, replicaID: String, dataAsOf: Date,
    partial: Bool, sources: [WidgetSource], permit: WidgetPublicationPermit? = nil,
    copyDatabase: (URL) throws -> Void
  ) throws {
    guard !workspaceID.isEmpty, !replicaID.isEmpty, dataAsOf.timeIntervalSince1970.isFinite,
      sources.count <= 64, Set(sources.map { Data($0.id.utf8) }).count == sources.count,
      sources.allSatisfy({ source in
        !source.id.isEmpty && source.id.utf8.count <= 512 && source.title.utf8.count <= 2048
          && bytesEqual(source.plan.workspaceID, workspaceID)
          && bytesEqual(source.plan.replicaID, replicaID)
      })
    else { throw unavailable }
    let permit = try permit ?? beginPublication()
    guard permit.root == root.standardizedFileURL,
      try bytesEqual(permit.generation, revocationToken())
    else { throw unavailable }
    let accessGeneration = permit.generation
    let generation = UUID().uuidString.lowercased()
    let staging = root.appendingPathComponent(".staging-" + generation, isDirectory: true)
    try privateDirectory(staging)
    defer { try? FileManager.default.removeItem(at: staging) }
    let snapshot = staging.appendingPathComponent("snapshot.sqlite")
    try copyDatabase(snapshot)
    try protect(snapshot)
    let digest = try fingerprint(snapshot)
    // A source compiled before backup is usable only if every guard matches the
    // completed backup. No caller-supplied plan silently skips this validation.
    for source in sources {
      _ = try WidgetPlanReader(databaseURL: snapshot).read(
        plan: source.plan, workspaceID: workspaceID, replicaID: replicaID, now: dataAsOf)
    }
    let metadata = WidgetPublication(
      version: 1, generation: generation, accessGeneration: accessGeneration,
      workspaceID: workspaceID, replicaID: replicaID, dataAsOf: dataAsOf,
      partial: partial, sources: sources, databaseSHA256: digest)
    try write(metadata, to: staging.appendingPathComponent("manifest.json"), limit: 8_388_608)
    try withLock(exclusive: true) {
      guard try bytesEqual(accessGeneration, revocationToken()) else { throw unavailable }
      let destination = root.appendingPathComponent(generation, isDirectory: true)
      try FileManager.default.moveItem(at: staging, to: destination)
      do { try write(Pointer(generation: generation), to: pointer, limit: 4096) } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
      }
      // Pointer is committed. Cleanup failure must not misreport publication as
      // failed; obsolete regenerable generations may be reclaimed next time.
      if let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      {
        for entry in entries
        where UUID(uuidString: entry.lastPathComponent) != nil
          && entry.lastPathComponent != generation
        {
          try? FileManager.default.removeItem(at: entry)
        }
      }
      let retained = Set(sources.map { cacheKey(workspaceID, replicaID, $0.id) + ".json" })
      if let entries = try? FileManager.default.contentsOfDirectory(
        at: fallback, includingPropertiesForKeys: nil)
      {
        for entry in entries where !retained.contains(entry.lastPathComponent) {
          try? FileManager.default.removeItem(at: entry)
        }
      }
    }
  }

  public func withCurrentPublication<T>(_ body: (WidgetPublication, URL) throws -> T) throws -> T {
    try withLock(exclusive: false) {
      let current: Pointer = try decode(pointer, limit: 4096)
      guard UUID(uuidString: current.generation) != nil else { throw unavailable }
      let directory = root.appendingPathComponent(current.generation, isDirectory: true)
      let metadata: WidgetPublication = try decode(
        directory.appendingPathComponent("manifest.json"), limit: 8_388_608)
      guard metadata.version == 1, bytesEqual(metadata.generation, current.generation),
        metadata.sources.count <= 64
      else { throw unavailable }
      guard try bytesEqual(metadata.accessGeneration, revocationToken()) else { throw unavailable }
      return try body(metadata, directory.appendingPathComponent("snapshot.sqlite"))
    }
  }

  public func read(
    sourceID: String, workspaceID: String, replicaID: String,
    now: Date = Date(), saveSuccess: Bool = true
  ) -> WidgetReadResult {
    do {
      return try withCurrentPublication { metadata, snapshot in
        guard bytesEqual(metadata.workspaceID, workspaceID),
          bytesEqual(metadata.replicaID, replicaID),
          let source = metadata.sources.first(where: { bytesEqual($0.id, sourceID) })
        else { return WidgetReadResult(state: .unavailable, content: nil) }
        let cache = fallback.appendingPathComponent(
          cacheKey(workspaceID, replicaID, sourceID) + ".json")
        do {
          guard try fingerprint(snapshot) == metadata.databaseSHA256 else { throw unavailable }
          let result = try WidgetPlanReader(databaseURL: snapshot).read(
            plan: source.plan, workspaceID: workspaceID, replicaID: replicaID, now: now)
          let content = WidgetContent(
            workspaceID: workspaceID, replicaID: replicaID,
            sourceID: sourceID, title: source.title, rows: result.rows, dataAsOf: metadata.dataAsOf,
            partial: metadata.partial, effectiveDay: result.effectiveDay,
            nextBoundary: result.nextBoundary, calendarPolicy: source.plan.calendarPolicy)
          if saveSuccess { try? write(content, to: cache, limit: 1_048_576) }
          let failed: Pointer? = try? decode(
            root.appendingPathComponent("refresh-failed.json"), limit: 4096)
          return WidgetReadResult(
            state: failed?.generation == metadata.generation ? .stale : .current, content: content)
        } catch {
          // Authorization and source membership were checked in the current
          // publication first. Missing/protected/revoked metadata never falls back.
          let old: WidgetContent? = try? decode(cache, limit: 1_048_576)
          guard let old, bytesEqual(old.workspaceID, workspaceID),
            bytesEqual(old.replicaID, replicaID), bytesEqual(old.sourceID, sourceID)
          else {
            return WidgetReadResult(state: .unavailable, content: nil)
          }
          return WidgetReadResult(state: .stale, content: old)
        }
      }
    } catch { return WidgetReadResult(state: .unavailable, content: nil) }
  }

  public func revoke() throws {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    try withLock(exclusive: true) {
      // Remove authority first. A later cleanup failure cannot expose fallback.
      try write(
        Pointer(generation: UUID().uuidString), to: root.appendingPathComponent("revocation.json"),
        limit: 4096)
      if FileManager.default.fileExists(atPath: pointer.path) {
        try FileManager.default.removeItem(at: pointer)
      }
      for entry in try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
      where entry.lastPathComponent == "fallback"
        || UUID(uuidString: entry.lastPathComponent) != nil
      {
        try FileManager.default.removeItem(at: entry)
      }
    }
  }

  private func revocationToken() throws -> String {
    let url = root.appendingPathComponent("revocation.json")
    do {
      let token: Pointer = try decode(url, limit: 4096)
      return token.generation
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    { return "" }
  }

  private func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
    let url = root.appendingPathComponent("publication.lock")
    let flags = exclusive ? O_RDWR | O_CREAT : O_RDONLY
    let descriptor = Darwin.open(url.path, flags, mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else { throw unavailable }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
      throw unavailable
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}

private let unavailable = ExtensionReadError(
  message: "Widget publication is unavailable. Open the app to refresh.")
private func bytesEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
private func cacheKey(_ workspace: String, _ replica: String, _ source: String) -> String {
  let data = (try? JSONEncoder().encode([workspace, replica, source])) ?? Data()
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func privateDirectory(_ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try protect(url)
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  var mutable = url
  try mutable.setResourceValues(values)
}
private func protect(_ url: URL) throws {
  #if os(iOS)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
  #endif
}
private func write<T: Encodable>(_ value: T, to url: URL, limit: Int) throws {
  let data = try JSONEncoder().encode(value)
  guard data.count <= limit else { throw unavailable }
  try data.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  try protect(url)
}
private func decode<T: Decodable>(_ url: URL, limit: Int) throws -> T {
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
  guard values.isSymbolicLink != true, let size = values.fileSize, size <= limit else {
    throw unavailable
  }
  let data = try Data(contentsOf: url)
  guard data.count <= limit else { throw unavailable }
  return try JSONDecoder().decode(T.self, from: data)
}
private func fingerprint(_ url: URL) throws -> String {
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
  guard values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= 536_870_912
  else { throw unavailable }
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var digest = SHA256()
  var total = 0
  while let data = try handle.read(upToCount: 262144), !data.isEmpty {
    total += data.count
    guard total <= 536_870_912 else { throw unavailable }
    digest.update(data: data)
  }
  guard total == size else { throw unavailable }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
