#if DEBUG && os(macOS)
  import Foundation
  import SwiftUI

  /// Explicit development fixture, independent of the installed user's stores.
  @MainActor public final class NativeUITestProfile {
    public let preferences: UserDefaults
    public let suiteName: String
    private let root: URL

    public convenience init(root: URL) throws {
      try self.init(root: root, preferencesFactory: { UserDefaults(suiteName: $0) })
    }

    init(root: URL, preferencesFactory: (String) -> UserDefaults?) throws {
      let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      let canonical = root.resolvingSymlinksInPath()
      guard root.isFileURL, canonical.deletingLastPathComponent() == temporary,
        canonical.lastPathComponent == root.lastPathComponent,
        canonical.lastPathComponent.hasPrefix("iris-ui-"),
        let id = UUID(uuidString: String(canonical.lastPathComponent.dropFirst(8))),
        canonical.lastPathComponent == "iris-ui-" + id.uuidString.lowercased()
      else { throw CocoaError(.fileReadNoPermission) }
      let owner = id.uuidString.lowercased()
      let marker = canonical.appendingPathComponent(".native-ui-profile")
      if FileManager.default.fileExists(atPath: marker.path) {
        try Self.validateContents(canonical)
        guard !(try marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false),
          try Data(contentsOf: marker) == Data(owner.utf8)
        else { throw CocoaError(.fileReadNoPermission) }
      } else {
        if FileManager.default.fileExists(atPath: canonical.path) {
          guard try FileManager.default.contentsOfDirectory(atPath: canonical.path).isEmpty else {
            throw CocoaError(.fileReadNoPermission)
          }
        }
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try Data(owner.utf8).write(to: marker, options: .atomic)
      }
      suiteName = "iris.synthetic." + owner
      guard let preferences = preferencesFactory(suiteName) else {
        throw CocoaError(.fileReadUnknown)
      }
      self.preferences = preferences
      self.root = canonical
    }

    func makeWorkspaceModel() -> WorkspaceModel {
      let canonical = root
      let services = HubServicesModel(
        alerts: NotificationAlerts(
          directory: canonical.appendingPathComponent("alerts"), delivery: SyntheticDelivery()),
        pushDevice: SyntheticPushDevice(),
        defaultAlertsDirectory: {
          preconditionFailure("Synthetic profile reached installed alert storage")
        })
      return WorkspaceModel(
        localURL: {
          try Self.validateContents(canonical)
          return canonical.appendingPathComponent("local.sqlite")
        },
        makeTransport: { _ in throw CocoaError(.featureUnsupported) },
        credentialStore: SyntheticCredentials(), widgetLibrary: nil, services: services,
        changeSignal: { _ in nil })
    }

    private static func validateContents(_ root: URL) throws {
      var traversalError: Error?
      guard
        let entries = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [], options: [],
          errorHandler: { _, error in
            traversalError = error
            return false
          })
      else { throw CocoaError(.fileReadNoPermission) }
      for case let entry as URL in entries {
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
        let type = attributes[.type] as? FileAttributeType
        guard
          type == .typeDirectory
            || (type == .typeRegular && (attributes[.referenceCount] as? NSNumber)?.intValue == 1),
          entry.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
        else { throw CocoaError(.fileReadNoPermission) }
      }
      if let traversalError { throw traversalError }
    }

    public static func configured(environment: [String: String]) throws -> NativeUITestProfile? {
      guard let path = environment["IRIS_UI_TEST_PROFILE_ROOT"] else { return nil }
      guard !path.isEmpty else { throw CocoaError(.fileReadNoPermission) }
      return try NativeUITestProfile(root: URL(fileURLWithPath: path))
    }

    public func workspace(demo: Bool) -> some View {
      WorkspaceView(model: makeWorkspaceModel(), demo: demo).defaultAppStorage(preferences)
    }
  }

  private struct SyntheticCredentials: HubCredentialStorage {
    func load() throws -> HubCredentials? { nil }
    func save(_ credentials: HubCredentials) throws { throw CocoaError(.featureUnsupported) }
    func remove() throws { throw CocoaError(.featureUnsupported) }
  }

  @MainActor private struct SyntheticDelivery: NotificationDelivery {
    func requestAuthorization() async throws -> Bool { throw CocoaError(.featureUnsupported) }
    func present(
      _ notification: HubNotification, identifier: String, shouldPresent: () throws -> Bool
    ) async throws -> Bool { throw CocoaError(.featureUnsupported) }
  }

  @MainActor private final class SyntheticPushDevice: PushNotificationDevice {
    var token: Data? { nil }
    var error: String? { nil }
    var platform: CorePushPlatform { .macos }
    func register() { preconditionFailure("Synthetic profile cannot register a device") }
    func observe(_ observer: @escaping (Data) -> Void) -> UUID {
      preconditionFailure("Synthetic profile cannot observe a device")
    }
    func removeObserver(_ id: UUID) {}
  }
#endif
