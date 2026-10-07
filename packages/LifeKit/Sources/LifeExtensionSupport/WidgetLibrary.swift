import CryptoKit
import Foundation

public struct WidgetSourceDescriptor: Sendable, Identifiable {
  public let id: String
  public let title: String
  public let workspaceID: String
  public let replicaID: String
  public let table: String
  public let viewID: String?
  public let kind: CoreReadPlanKind
  public let displayColumn: String?
  public let usesCalendar: Bool
}

/// A bounded picker catalog of authorized publications, without record bodies,
/// SQL, credentials or a second index. Workspaces retain independent generations.
public struct WidgetLibrary: Sendable {
  public let root: URL
  public init(root: URL) { self.root = root }

  public static func installed(bundle: Bundle = .main) -> Self? {
    guard let group = bundle.object(forInfoDictionaryKey: "LifeWidgetAppGroup") as? String,
      group.hasPrefix("group."), !group.contains("$"),
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return Self(root: container.appendingPathComponent("WidgetPublications", isDirectory: true))
  }

  public func store(workspaceID: String) -> WidgetPublicationStore {
    WidgetPublicationStore(
      root: root.appendingPathComponent(digest(Data(workspaceID.utf8)), isDirectory: true))
  }

  public static func sourceID(
    workspaceID: String, table: String, viewID: String?, kind: CoreReadPlanKind
  ) -> String {
    // An ordered array has one stable encoding and preserves exact UTF-8 values.
    let identity: [String?] = [workspaceID, table, viewID, kind.rawValue]
    return digest(try! JSONEncoder().encode(identity))
  }

  public func sources() throws -> [WidgetSourceDescriptor] {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    // Refuse an unbounded/corrupt catalog instead of silently hiding workspaces.
    let directories = entries.filter {
      $0.lastPathComponent.utf8.count == 64
        && $0.lastPathComponent.utf8.allSatisfy {
          (48...57).contains($0) || (97...102).contains($0)
        }
    }
    guard directories.count <= 32 else {
      throw ExtensionReadError(message: "Open the app to review widget sources.")
    }
    var result: [WidgetSourceDescriptor] = []
    for directory in directories {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
      let store = WidgetPublicationStore(root: directory)
      // A revoked, protected or incomplete generation supplies no picker labels.
      let sources = try? store.withCurrentPublication { metadata, _ -> [WidgetSourceDescriptor] in
        guard digest(Data(metadata.workspaceID.utf8)) == directory.lastPathComponent else {
          return []
        }
        return metadata.sources.map { source in
          WidgetSourceDescriptor(
            id: source.id, title: source.title,
            workspaceID: metadata.workspaceID, replicaID: metadata.replicaID,
            table: source.plan.table, viewID: source.plan.viewID, kind: source.plan.kind,
            displayColumn: source.plan.displayColumn,
            usesCalendar: source.plan.parameters.contains {
              if case .calendar = $0 { return true }
              return false
            })
        }
      }
      result.append(contentsOf: sources ?? [])
    }
    return result.sorted { Data($0.id.utf8).lexicographicallyPrecedes(Data($1.id.utf8)) }
  }
}

private func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
