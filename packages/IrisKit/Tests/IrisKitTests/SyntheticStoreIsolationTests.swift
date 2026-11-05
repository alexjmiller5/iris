import Foundation
import Testing

@testable import IrisKit

@MainActor struct SyntheticStoreIsolationTests {
  @Test func injectedAlertsNeverResolveTheInstalledDirectory() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var sharedDirectoryCalls = 0
    let alerts = NotificationAlerts(directory: root, delivery: FixtureNotificationDelivery())
    _ = HubServicesModel(
      alerts: alerts, pushDevice: IsolationPushDevice(),
      defaultAlertsDirectory: {
        sharedDirectoryCalls += 1
        Issue.record("Injected services must not resolve installed device state")
        return root
      })
    #expect(sharedDirectoryCalls == 0)
  }

  @Test func defaultAlertsResolveOnlyTheExplicitDirectory() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var directoryCalls = 0
    _ = HubServicesModel(
      pushDevice: IsolationPushDevice(),
      defaultAlertsDirectory: {
        directoryCalls += 1
        return root
      })
    #expect(directoryCalls == 1)
  }

  @Test func syntheticWorkspaceRetainsInjectedDeviceAndCredentialStores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let services = HubServicesModel(
      alerts: NotificationAlerts(
        directory: root.appendingPathComponent("alerts"), delivery: FixtureNotificationDelivery()),
      pushDevice: IsolationPushDevice(),
      defaultAlertsDirectory: {
        Issue.record("Synthetic model must never select installed alert state")
        return root
      })
    let model = WorkspaceModel(
      localURL: { root.appendingPathComponent("local.sqlite") },
      makeTransport: { _ in
        Issue.record("Synthetic workspace must never construct a live transport")
        throw URLError(.unsupportedURL)
      }, credentialStore: ForbiddenIsolationCredentials(), widgetLibrary: nil,
      services: services)
    #expect(model.services === services)
    await model.open()
    #expect(model.error == nil)
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("local.sqlite").path))
    #expect(!model.isReplica && model.canWrite)
    await model.close()
  }
}

@MainActor private final class IsolationPushDevice: PushNotificationDevice {
  var token: Data? { nil }
  var error: String? { nil }
  var platform: CorePushPlatform { .macos }
  func register() { Issue.record("Synthetic profile must never register a device") }
  func observe(_ observer: @escaping (Data) -> Void) -> UUID {
    Issue.record("Synthetic profile must never observe a device")
    return UUID()
  }
  func removeObserver(_ id: UUID) {}
}

private struct ForbiddenIsolationCredentials: HubCredentialStorage {
  func load() throws -> HubCredentials? {
    Issue.record("Synthetic local workspace must not read credentials")
    throw URLError(.userAuthenticationRequired)
  }
  func save(_ credentials: HubCredentials) throws {
    Issue.record("Synthetic profile must not save credentials")
    throw URLError(.userAuthenticationRequired)
  }
  func remove() throws {
    Issue.record("Synthetic profile must not remove credentials")
    throw URLError(.userAuthenticationRequired)
  }
}
