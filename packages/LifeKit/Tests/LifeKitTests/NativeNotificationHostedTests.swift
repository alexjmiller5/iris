#if os(macOS)
  import AppKit
  import CryptoKit
  import Observation
  import SwiftUI
  import Testing
  import UserNotifications

  @testable import LifeKit

  // Interactive, app-hosted acceptance only. Ordinary CI must never open this
  // window or request notification permission. This does not test enrollment,
  // the installed release, APNs, or closed-app delivery.
  @Suite(.serialized) @MainActor
  struct NativeNotificationHostedTests {
    // Compile the complete fixture in SwiftPM, but never run an unhosted GUI.
    #if SWIFT_PACKAGE
      @Test(.disabled("Requires the explicitly opted-in macOS XCTest app host"))
    #else
      @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_NATIVE_ALERTS"] == "1"))
    #endif
    func foregroundBannerThroughProductionServices() async throws {
      try #require(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
      try #require(Bundle.main.bundleURL.pathExtension == "app")

      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("notification-host-" + UUID().uuidString, isDirectory: true)
      let credentials = MemoryHubCredentials(nil)
      let model = WorkspaceModel(
        localURL: { root.appendingPathComponent("local.sqlite") }, credentialStore: credentials)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [HostedNotificationProtocol.self]
      let hub = try HubTransport(
        endpoint: "https://notification-host-\(UUID().uuidString.lowercased()).invalid",
        token: "fixture", configuration: configuration)
      let checkpoint = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("life-ui/alerts", isDirectory: true)
        .appendingPathComponent(notificationHostDigest(hub.endpoint) + ".json")
      // Never adopt or remove state that belonged to an earlier run.
      try #require(!FileManager.default.fileExists(atPath: checkpoint.path))
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let fixture = HostedNotificationSession(model: model, hub: hub)
      let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1100, height: 800),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = "Synthetic notification test host"

      do {
        try HostedNotificationProtocol.state.reset()
        await model.open(demo: true)
        let workspace = try #require(model.client)
        try #require(model.error == nil)
        // Configure only the services under test. There is no connect/enroll
        // operation and no saved credential, even in the memory-only store.
        model.services.configure(workspace: workspace, transport: hub)
        await model.services.refresh()
        try #require(model.services.notificationError == nil)
        try #require(model.services.feed?.notifications.count == 205)
        try #require(!model.services.alertsEnabled)
        let baseline = try JSONDecoder().decode(
          NotificationAlertState.self, from: Data(contentsOf: checkpoint))
        try #require(baseline.baseline == 205 && baseline.deliveredIDs.isEmpty)

        await recordNotificationSettings(phase: .beforeUI)
        window.contentView = NSHostingView(rootView: HostedNotificationView(fixture: fixture))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // The operator uses production Hub connection > Notifications > Enable
        // alerts, then Done before using the fixture controls. Only that explicit
        // production action may request OS permission. Capture the actual banner
        // separately; a scheduling receipt or delivered-list entry is not proof
        // of a visibly presented banner.
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        var recordedAuthorizationFailure = false
        while !fixture.finished && window.isVisible && ContinuousClock.now < deadline {
          try Task.checkCancellation()
          if !recordedAuthorizationFailure, !model.services.changingAlerts,
            model.services.alertError != nil
          {
            recordedAuthorizationFailure = true
            await recordNotificationSettings(phase: .authorizationFailure)
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        try #require(
          fixture.finished, "Interactive fixture timed out; no banner acceptance claimed")
        #expect(fixture.emitted)
        #expect(fixture.reconnected)
        #expect(fixture.sameDeliveryAfterReconnect)
        #expect(fixture.failure == nil)
        #expect(model.services.notificationError == nil)
        #expect(model.services.alertError == nil)
        #expect(credentials.value == nil)
        #expect(credentials.saves == 0)
        #expect(credentials.removals == 0)
        #expect(model.services.feed?.notifications.last?.id == HostedNotificationSession.eventID)
        #expect(
          model.services.feed?.notifications.last?.readAt != nil,
          "Use the production Mark read action after capturing the banner")
        #expect(model.services.unreadCount == 205)
        let state = try JSONDecoder().decode(
          NotificationAlertState.self, from: Data(contentsOf: checkpoint))
        #expect(state.baseline == 206)
        #expect(state.deliveredIDs == [HostedNotificationSession.eventID])
      } catch {
        await cleanup(window: window, fixture: fixture, checkpoint: checkpoint, root: root)
        throw error
      }
      await cleanup(window: window, fixture: fixture, checkpoint: checkpoint, root: root)
    }

    private enum NotificationSettingsPhase: String {
      case beforeUI = "before-ui"
      case authorizationFailure = "authorization-failure"
    }

    private func recordNotificationSettings(phase: NotificationSettingsPhase) async {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      let bundle = Bundle.main
      let isTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && bundle.bundleURL.pathExtension == "app"
      // Fixed phases and limited host metadata only; never paths or credentials.
      print(
        "notification-host phase=\(phase.rawValue)"
          + " authorizationStatus=\(settings.authorizationStatus.rawValue)"
          + " alertSetting=\(settings.alertSetting.rawValue)"
          + " bundleID=\(bundle.bundleIdentifier ?? "missing")"
          + " bundle=\(bundle.bundleURL.lastPathComponent)"
          + " executable=\(bundle.executableURL?.lastPathComponent ?? "missing")"
          + " isTestHost=\(isTestHost)")
    }

    private func cleanup(
      window: NSWindow, fixture: HostedNotificationSession, checkpoint: URL, root: URL
    ) async {
      // Keep the owned UI available while an explicit OS permission action is
      // pending. Closing the test window cannot cancel the system's callback.
      await fixture.stop()
      window.contentView = nil
      window.close()
      let center = UNUserNotificationCenter.current()
      center.removePendingNotificationRequests(withIdentifiers: [fixture.requestID])
      center.removeDeliveredNotifications(withIdentifiers: [fixture.requestID])
      // Do not clear the notification center, alert directory, or any Keychain
      // item. Permission is bundle-wide and is deliberately not reset here.
      for url in [checkpoint, root] where FileManager.default.fileExists(atPath: url.path) {
        do { try FileManager.default.removeItem(at: url) } catch {
          Issue.record(error, "Could not remove owned notification fixture state")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
      }
    }
  }

  @Observable @MainActor
  private final class HostedNotificationSession {
    static let eventID = "event-206"
    let model: WorkspaceModel
    let hub: HubTransport
    let requestID: String
    var emitted = false
    var reconnected = false
    var sameDeliveryAfterReconnect = false
    var finished = false
    var busy = false
    var stopping = false
    var failure: String?
    private var firstDelivery: Date?
    private var operation: Task<Void, Never>?

    init(model: WorkspaceModel, hub: HubTransport) {
      self.model = model
      self.hub = hub
      requestID =
        "life-ui." + notificationHostDigest(hub.endpoint) + "."
        + notificationHostDigest(Self.eventID)
    }

    func emit() {
      guard !stopping, !busy, !emitted, model.services.alertsEnabled, !model.services.refreshing
      else {
        return
      }
      busy = true
      operation = Task {
        defer { busy = false }
        HostedNotificationProtocol.state.appendEvent()
        emitted = true
        await model.services.refresh()
        do {
          firstDelivery = try await deliveredDate()
          #expect(
            model.services.feed?.notifications.last?.readAt == nil,
            "OS delivery must not acknowledge shared read state")
        } catch { failure = "No current OS delivery receipt: \(error.localizedDescription)" }
      }
    }

    func reconnect() {
      guard !stopping, !busy, emitted, let firstDelivery, let workspace = model.client,
        !model.services.refreshing
      else { return }
      busy = true
      operation = Task {
        defer { busy = false }
        model.services.configure(workspace: nil, transport: nil)
        model.services.configure(workspace: workspace, transport: hub)
        await model.services.refresh()
        await model.services.refresh()
        do {
          // add() can finish before the notification center updates its list.
          // Observe a short interval rather than accepting one stale list read.
          sameDeliveryAfterReconnect = true
          for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(200))
            if try await deliveredDate() != firstDelivery {
              sameDeliveryAfterReconnect = false
              break
            }
          }
          reconnected = true
          #expect(
            sameDeliveryAfterReconnect,
            "Reconnect/refresh must not replace the original OS delivery")
        } catch { failure = "Reconnect delivery check failed: \(error.localizedDescription)" }
      }
    }

    func stop() async {
      stopping = true
      operation?.cancel()
      await operation?.value
      operation = nil
      // Enable alerts runs a production task outside `operation`. Its permission
      // callback saves the checkpoint before clearing changingAlerts. Do not
      // invalidate its generation or delete that file while it can still write.
      // An unstructured task does not inherit cancellation of the test, so this
      // drain also works during canceled-test cleanup without a busy spin.
      let permissionDrain = Task { @MainActor in
        while model.services.changingAlerts {
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      await permissionDrain.value
      model.services.configure(workspace: nil, transport: nil)
      await model.close()
    }

    private func deliveredDate() async throws -> Date {
      for _ in 0..<50 {
        try Task.checkCancellation()
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        if let owned = notifications.first(where: { $0.request.identifier == requestID }) {
          return owned.date
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw URLError(.timedOut)
    }
  }

  private struct HostedNotificationView: View {
    let fixture: HostedNotificationSession

    var body: some View {
      VStack(spacing: 0) {
        WorkspaceView(model: fixture.model)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text("Test host only: open Hub connection > Notifications > Enable alerts, then Done.")
          Text(
            "Emit, capture the real banner, reconnect, then mark Synthetic event 206 read in Notifications."
          )
          .font(.caption)
          HStack {
            Button("Emit fixture event") { fixture.emit() }
              .disabled(
                fixture.busy || fixture.emitted || !fixture.model.services.alertsEnabled
                  || fixture.model.services.refreshing)
            Button("Reconnect fixture") { fixture.reconnect() }
              .disabled(fixture.busy || !fixture.emitted || fixture.model.services.refreshing)
            Button("Finish fixture") { fixture.finished = true }
              .disabled(fixture.busy)
          }
          if let failure = fixture.failure { Text(failure).foregroundStyle(.red) }
        }.padding()
      }.disabled(fixture.stopping)
    }
  }

  // This URLSession-local protocol never falls through to real networking.
  // Its state is separate from other notification suites' static fixtures.
  private final class HostedNotificationProtocol: URLProtocol, @unchecked Sendable {
    static let state = ServiceFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      do {
        guard let url = request.url, url.scheme == "https",
          url.host?.hasPrefix("notification-host-") == true,
          url.host?.hasSuffix(".invalid") == true
        else { throw URLError(.unsupportedURL) }
        let (status, body) = try Self.state.reply(request)
        guard
          let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])
        else { throw URLError(.badServerResponse) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try JSONEncoder().encode(body))
        client?.urlProtocolDidFinishLoading(self)
      } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
  }

  private func notificationHostDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
#endif
