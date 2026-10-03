import CryptoKit
import Foundation
import Testing

@testable import LifeKit

@Suite(.serialized) @MainActor
struct EnrollmentLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_HUB"] != nil))
  func actualWorkerApprovalIdentityScopedSyncAndRevocation() async throws {
    let endpoint = try await fixtureEndpoint()
    let core = try EnrollmentCore()
    let policy = try await core.policy(fingerprint: String(repeating: "a", count: 64))
    let admin = try await HubTransport(endpoint: endpoint, token: "operator-fixture").sessionReply(
      maxResponseBytes: policy.maxResponseBytes)
    await #expect(throws: Error.self) {
      try await core.request(
        CoreRequests.ValidateDeviceSession(CoreSessionDataArgs(data: admin.data)))
    }
    let restricted = try await HubTransport(endpoint: endpoint, token: "restricted-fixture")
      .sessionReply(maxResponseBytes: policy.maxResponseBytes)
    #expect(
      try await core.request(
        CoreRequests.ValidateDeviceSession(CoreSessionDataArgs(data: restricted.data))
      ).replica.allowed == false)
    let candidate = try DeviceCandidate.generate()
    let hub = try HubTransport(endpoint: endpoint, token: candidate.token)
    let pending = try await hub.sessionReply(maxResponseBytes: policy.maxResponseBytes)
    #expect(
      try await core.request(
        CoreRequests.EnrollmentPollResult(
          CoreEnrollmentPollArgs(reply: pending, expectedFingerprint: candidate.fingerprint))
      ).state == .pending)
    let earlyCleanup = try await hub.sessionReply(
      revoking: true, maxResponseBytes: policy.maxResponseBytes)
    #expect(
      try await core.request(CoreRequests.SessionRevocationResult(earlyCleanup)).state
        == .unauthorized)
    try await approve(endpoint: endpoint, candidate: candidate)
    let approved = try await hub.sessionReply(maxResponseBytes: policy.maxResponseBytes)
    let result = try await core.request(
      CoreRequests.EnrollmentPollResult(
        CoreEnrollmentPollArgs(reply: approved, expectedFingerprint: candidate.fingerprint)))
    #expect(result.session?.replica.allowed == true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MemoryHubCredentials(nil)
    let model = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, credentialStore: store)
    try await model.connect(
      HubCredentials(endpoint: endpoint, token: candidate.token),
      expectedFingerprint: candidate.fingerprint)
    #expect(model.connection == store.value && model.syncResult != nil)
    let workspace = try #require(model.client)
    let created = try await workspace.write(
      table: "widgets",
      patch: ["title": .string("Enrolled fixture \(UUID().uuidString)"), "quantity": .number(9)])
    await model.synchronize()
    #expect(model.syncStatus?.pendingUiEdits == 0)
    let remote = try await workspace.remoteRow(
      using: hub, table: "widgets", id: #require(created["id"]?.text))
    #expect(remote.row?.record["quantity"] == .number(9))
    let revoked = try await hub.sessionReply(
      revoking: true, maxResponseBytes: policy.maxResponseBytes)
    #expect(try await core.request(CoreRequests.SessionRevocationResult(revoked)).state == .revoked)
    #expect(try await hub.sessionReply(maxResponseBytes: policy.maxResponseBytes).status == 401)
    await model.synchronize()
    #expect(
      model.client === workspace && !model.rows.isEmpty,
      "Revocation must not erase cached local records")
    await model.close()
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFE_UI_TEST_HUB"] != nil))
  func actualWorkerCandidateIsRevokedAfterKeychainInstallationFails() async throws {
    let endpoint = try await fixtureEndpoint()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = HubCredentials(endpoint: endpoint, token: "fixture")
    let store = MemoryHubCredentials(old)
    store.failSave = true
    let workspace = WorkspaceModel(
      localURL: { directory.appendingPathComponent("local.sqlite") }, credentialStore: store)
    await workspace.open(demo: true)
    let original = workspace.client
    let candidate = try DeviceCandidate.generate()
    try await approve(endpoint: endpoint, candidate: candidate)
    let enrollment = EnrollmentModel(
      candidate: { candidate },
      install: { credentials, fingerprint, current in
        try await workspace.connect(
          credentials, expectedFingerprint: fingerprint, synchronizeAfter: false, isCurrent: current
        )
      })
    await enrollment.start(endpoint: endpoint, name: "Synthetic failed installation")
    #expect(enrollment.phase == .idle)
    #expect(enrollment.cleanupMessage == "Device credential revoked.")
    #expect(store.value == old && workspace.client === original)
    let reply = try await HubTransport(endpoint: endpoint, token: candidate.token).sessionReply(
      maxResponseBytes: 65_536)
    #expect(reply.status == 401)
    await workspace.close()
  }

  private func fixtureEndpoint() async throws -> String {
    let value = try #require(ProcessInfo.processInfo.environment["LIFE_UI_TEST_HUB"])
    let url = try #require(URL(string: value))
    try #require(
      url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? ""))
    let reply = try await HubTransport(endpoint: value, token: "fixture").sessionReply(
      maxResponseBytes: 65_536)
    try #require(
      reply.data
        == .object(["name": .string("Example device"), "scopes": .array([.string("full")])]))
    return value
  }

  private func approve(endpoint: String, candidate: DeviceCandidate) async throws {
    let core = try EnrollmentCore()
    let approval = try await core.request(
      CoreRequests.EnrollmentApproval(
        CoreEnrollmentApprovalArgs(
          fingerprint: candidate.fingerprint, name: "Synthetic native device")))
    let url = try #require(URL(string: endpoint + approval.path))
    let (page, pageReply) = try await URLSession.shared.data(from: url)
    try #require((pageReply as? HTTPURLResponse)?.statusCode == 200)
    #expect(!String(decoding: page, as: UTF8.self).contains(candidate.token))
    var request = URLRequest(url: try #require(URL(string: endpoint + "/login")))
    request.httpMethod = "POST"
    request.setValue(endpoint, forHTTPHeaderField: "Origin")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        .utf8)
    let (_, response) = try await URLSession.shared.data(for: request)
    try #require((response as? HTTPURLResponse)?.statusCode == 200)
  }
}
