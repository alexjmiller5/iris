import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor struct HubServicesTests {
  @Test func confirmedPushSuppressesPollingButKeepsInboxAndReadState() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    let device = ServicePushDevice()
    let model = HubServicesModel(
      alerts: alerts, pushDevice: device,
      pushSession: { _ in
        CoreSessionInfo(
          name: "fixture", scopes: ["full"], replica: .init(allowed: true, reason: nil),
          pushRegistration: .init(
            protocol: "apns-registration-v1", deploymentIdentity: "deployment",
            sessionBinding: "session", profiles: [.init(id: "desktop", platform: .macos)]))
      })
    model.configure(workspace: workspace, transport: hub)
    await model.enableAlerts()
    #expect(device.registrations == 1)
    #expect(!model.pushReady)
    device.error = "Registration failed"
    #expect(model.pushError == "Registration failed")
    await model.refresh()
    #expect(device.registrations == 2)
    #expect(device.error == nil)
    ServiceFixture.state.appendEvent()
    await model.refresh()
    #expect(delivery.delivered.count == 1, "Before an OS token and receipt, local alerts remain")
    device.deliver(Data([0xaa]))
    for _ in 0..<500 where !model.pushReady { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.pushReady)
    ServiceFixture.state.appendEvent()
    await model.refresh()
    #expect(model.feed?.latestCursor == 207)
    #expect(model.unreadCount == 207)
    #expect(delivery.delivered.count == 1)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 207)
    await model.markRead(id: "event-207")
    #expect(model.unreadCount == 206)
    model.disableAlerts()
    #expect(!model.pushReady)
    model.configure(workspace: nil, transport: nil)
    try await workspace.close()
  }

  @Test func deliveryFailureRecomputesCoreProposalAfterRelaunch() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    await model.enableAlerts()
    ServiceFixture.state.appendEvent()
    ServiceFixture.state.appendEvent()
    delivery.failID = "event-207"
    await model.refresh()
    #expect(model.alertError != nil)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 205)
    #expect(delivery.delivered.count == 1)
    delivery.failID = nil
    let reopened = HubServicesModel(
      alerts: NotificationAlerts(directory: directory, delivery: delivery))
    reopened.configure(workspace: workspace, transport: hub)
    await reopened.refresh()
    #expect(reopened.alertError == nil)
    #expect(delivery.delivered.count == 2)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 207)
    try await workspace.close()
  }

  @Test func switchingDeploymentDuringDeliveryStopsOldEvents() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    await model.enableAlerts()
    ServiceFixture.state.appendEvent()
    ServiceFixture.state.appendEvent()
    delivery.onPresent = { [weak model] in model?.configure(workspace: nil, transport: nil) }
    await model.refresh()
    #expect(delivery.delivered.count == 1)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 205)
    #expect(model.feed == nil)
    try await workspace.close()
  }

  @Test func foregroundPollingCancelsAndExplicitEnableDeliversOnlyNewEvents() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let model = HubServicesModel(
      alerts: NotificationAlerts(directory: directory, delivery: delivery))
    model.configure(workspace: workspace, transport: hub)
    let polling = Task { await model.poll() }
    for _ in 0..<100 where model.feed == nil || model.refreshing {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.feed?.notifications.count == 205)
    #expect(ServiceFixture.state.usageRequests == 0)
    #expect(delivery.authorizationRequests == 0)
    polling.cancel()
    await polling.value
    #expect(!model.refreshing)
    await model.enableAlerts()
    #expect(delivery.authorizationRequests == 1)
    #expect(model.alertsEnabled)
    #expect(delivery.delivered.isEmpty)
    ServiceFixture.state.appendEvent()
    await model.refresh()
    #expect(delivery.delivered.count == 1)
    await model.refresh()
    #expect(delivery.delivered.count == 1)
    model.disableAlerts()
    #expect(!model.alertsEnabled)
    try await workspace.close()
  }

  @Test func modelReadsServicesWithoutASyncAndReconcilesSharedReadState() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let delivery = FixtureNotificationDelivery()
    let alerts = NotificationAlerts(directory: directory, delivery: delivery)
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    await model.refreshUsage()
    await model.refresh()
    #expect(model.usage?.metrics.count == 4)
    #expect(model.unreadCount == 205)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == 205)
    #expect(delivery.authorizationRequests == 0)
    #expect(delivery.delivered.isEmpty)
    await model.markRead(id: "event-205")
    #expect(model.unreadCount == 204)
    #expect(model.feed?.notifications.last?.readAt != nil)
    await model.markRead()
    #expect(model.unreadCount == 0)
    model.configure(workspace: nil, transport: nil)
    #expect(model.usage == nil && model.feed == nil && !model.connected)
    try await workspace.close()
  }

  @Test func incompleteNotificationRefreshKeepsUsageAndDoesNotPersistBaseline() async throws {
    let hub = try ServiceFixture.transport()
    ServiceFixture.state.failSecondPage = true
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let alerts = NotificationAlerts(directory: directory, delivery: FixtureNotificationDelivery())
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    await model.refreshUsage()
    await model.refresh()
    #expect(model.usage?.metrics.count == 4)
    #expect(model.feed == nil)
    #expect(model.notificationError != nil)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == nil)
    try await workspace.close()
  }

  @Test func disconnectDuringRefreshDiscardsOldDeploymentResults() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let alerts = NotificationAlerts(directory: directory, delivery: FixtureNotificationDelivery())
    let model = HubServicesModel(alerts: alerts)
    model.configure(workspace: workspace, transport: hub)
    let refresh = Task { await model.refresh() }
    let usageRefresh = Task { await model.refreshUsage() }
    await Task.yield()
    model.configure(workspace: nil, transport: nil)
    await refresh.value
    await usageRefresh.value
    #expect(model.feed == nil && model.usage == nil)
    #expect(model.usageError == nil && model.notificationError == nil)
    #expect(!model.refreshing && !model.usageRefreshing)
    #expect(try alerts.state(endpoint: hub.endpoint).baseline == nil)
    try await workspace.close()
  }

  @Test func actualCoreReadsAllPagesSuppressesHistoryAndMarksDeploymentRead() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let feed = try await workspace.notifications(using: hub)
    #expect(feed.notifications.count == 205)
    #expect(feed.unreadCount == 205)
    #expect(feed.notifications.last?.seq == 205)
    let first = try await workspace.notificationPresentation(feed, baseline: nil)
    #expect(first.notifications.isEmpty)
    #expect(first.baseline == 205)
    let subsequent = try await workspace.notificationPresentation(feed, baseline: 200)
    #expect(subsequent.notifications.map(\.seq) == [201, 202, 203, 204, 205])
    #expect(subsequent.baseline == 205)
    #expect(
      try await workspace.markNotificationsRead(
        using: hub, selector: ["ids": .array([.string("event-205")])]
      ).unreadCount == 204)
    let reread = try await workspace.notifications(using: hub)
    #expect(reread.notifications.last?.readAt != nil)
    #expect(
      try await workspace.notificationPresentation(reread, baseline: 204).notifications.isEmpty)
    #expect(
      try await workspace.markNotificationsRead(using: hub, selector: ["through": .number(205)])
        .unreadCount == 0)
    try await workspace.close()
  }

  @Test func exactUsageFixturePreservesUnmeasuredAndDistinctLimits() async throws {
    let hub = try ServiceFixture.transport()
    let workspace = try NativeWorkspace(path: ":memory:")
    let usage = try await workspace.usage(using: hub)
    #expect(usage.period.end == "2026-11-01T00:00:00.000Z")
    #expect(usage.metrics.count == 4)
    #expect(usage.metrics["d1_rows_read"]?.used == 1_234_567_890)
    #expect(usage.metrics["requests"]?.allowance == 10_000_000)
    #expect(usage.metrics["requests"]?.cap == nil)
    #expect(usage.metrics["d1_storage_bytes"]?.used == nil)
    #expect(usage.byPrincipal.first?.rowsRead == 1_000_000_000)
    #expect(usage.byPrincipal.last?.label == nil)
    try await workspace.close()
  }

  @Test func incompleteFeedFailsWithoutReturningAPresentationCheckpoint() async throws {
    let hub = try ServiceFixture.transport()
    ServiceFixture.state.failSecondPage = true
    let workspace = try NativeWorkspace(path: ":memory:")
    await #expect(throws: Error.self) { try await workspace.notifications(using: hub) }
    ServiceFixture.state.failSecondPage = false
    #expect(try await workspace.notifications(using: hub).notifications.count == 205)
    try await workspace.close()
  }
}

final class ServiceFixture: URLProtocol, @unchecked Sendable {
  static let state = ServiceFixtureState()
  static func transport() throws -> HubTransport {
    try state.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ServiceFixture.self]
    return try HubTransport(
      endpoint: "https://services.invalid", token: "fixture", configuration: config)
  }
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "services.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.state.reply(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONEncoder().encode(body))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

final class ServiceFixtureState: @unchecked Sendable {
  private let lock = NSLock()
  private var fixture: WorkspaceRecord = [:]
  private var read: Set<String> = []
  private var secondPageFailure = false
  private var eventCount = 205
  private var usageReadCount = 0
  var usageRequests: Int { lock.withLock { usageReadCount } }
  func appendEvent() { lock.withLock { eventCount += 1 } }
  var failSecondPage: Bool {
    get { lock.withLock { secondPageFailure } }
    set { lock.withLock { secondPageFailure = newValue } }
  }
  func reset() throws {
    #if SWIFT_PACKAGE
      let bundle = Bundle.module
    #else
      let bundle = Bundle(for: ServiceFixture.self)
    #endif
    let url = try #require(
      bundle.url(forResource: "hub-usage-contract", withExtension: "json", subdirectory: "Fixtures")
        ?? bundle.url(forResource: "hub-usage-contract", withExtension: "json"))
    let data = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(contentsOf: url))
    lock.withLock {
      fixture = data
      read = []
      secondPageFailure = false
      eventCount = 205
      usageReadCount = 0
    }
  }
  func reply(_ request: URLRequest) throws -> (Int, JSONValue) {
    try lock.withLock {
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" else {
        return (401, .object([:]))
      }
      switch request.url!.path {
      case "/v1/push/registration":
        if request.httpMethod == "GET" {
          return (200, .object(["kind": .string("available"), "registration": .null]))
        }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
          stream.open()
          defer { stream.close() }
          var buffer = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[..<count])
          }
        }
        let body = try JSONDecoder().decode(CorePushRegistrationRequest.self, from: data)
        let receipt = CorePushRegistrationReceipt(
          requestId: body.requestId,
          registration: .init(
            installationId: "installation", revision: "revision", state: .active,
            deploymentIdentity: "deployment", sessionBinding: "session", appProfile: "desktop",
            activatedAfterSeq: 205, updatedAt: "2026-01-01T00:00:00.000Z"))
        return (
          200,
          .object([
            "kind": .string("confirmed"),
            "receipt": try JSONDecoder().decode(
              JSONValue.self, from: JSONEncoder().encode(receipt)),
          ])
        )
      case "/v1/usage":
        usageReadCount += 1
        guard request.httpMethod == "GET", case .object(var usage) = fixture["usage"],
          case .object(var metrics) = usage["metrics"],
          case .object(var storage) = metrics["d1_storage_bytes"]
        else { throw URLError(.badServerResponse) }
        storage["used"] = .null
        metrics["d1_storage_bytes"] = .object(storage)
        usage["metrics"] = .object(metrics)
        return (200, .object(usage))
      case "/v1/notifications":
        guard request.httpMethod == "GET" else { throw URLError(.badServerResponse) }
        let query =
          URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let after = Int(query.first { $0.name == "after" }?.value ?? "") ?? -1
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "") ?? 0
        guard after >= 0, limit > 0 else { throw URLError(.badServerResponse) }
        if after > 0, secondPageFailure { return (503, .object([:])) }
        let end = min(after + limit, eventCount)
        let rows: [JSONValue] =
          after < eventCount
          ? ((after + 1)...end).map { seq in
            .object([
              "seq": .number(Double(seq)), "id": .string("event-\(seq)"),
              "created_at": .string("2026-10-02T15:04:05.123Z"),
              "producer": .string("generic-fixture"), "type": .string("other.event"),
              "severity": .string("info"), "title": .string("Synthetic event \(seq)"),
              "body": .string("Generic message body"), "data": .object(["unknown": .bool(true)]),
              "read_at": read.contains("event-\(seq)")
                ? .string("2026-10-02T16:00:00.000Z") : .null,
            ])
          } : []
        return (
          200,
          .object([
            "notifications": .array(rows),
            "next_cursor": end < eventCount ? .number(Double(end)) : .null,
            "latest_cursor": .number(Double(eventCount)),
            "unread_count": .number(Double(eventCount - read.count)),
          ])
        )
      case "/v1/notifications/read":
        guard request.httpMethod == "POST" else { throw URLError(.badServerResponse) }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
          stream.open()
          defer { stream.close() }
          var buffer = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[..<count])
          }
        }
        let body = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        if case .array(let ids) = body["ids"] { for id in ids { read.insert(id.text) } }
        if case .number(let through) = body["through"], through >= 1 {
          for seq in 1...min(Int(through), eventCount) { read.insert("event-\(seq)") }
        }
        return (200, .object(["unread_count": .number(Double(eventCount - read.count))]))
      default: throw URLError(.badURL)
      }
    }
  }
}

@MainActor private final class ServicePushDevice: PushNotificationDevice {
  var token: Data?
  var error: String?
  var platform: CorePushPlatform { .macos }
  var registrations = 0
  func register() { registrations += 1; error = nil }
  private var observers: [UUID: (Data) -> Void] = [:]
  func observe(_ observer: @escaping (Data) -> Void) -> UUID {
    let id = UUID()
    observers[id] = observer
    return id
  }
  func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  func deliver(_ token: Data) {
    self.token = token
    for observer in observers.values { observer(token) }
  }
}
