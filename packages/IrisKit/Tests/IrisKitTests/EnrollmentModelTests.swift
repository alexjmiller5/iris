import CryptoKit
import Foundation
import Testing

@testable import IrisKit

@MainActor
struct EnrollmentModelTests {
  @Test func candidateUsesFreshSecureBytesAndOnlyItsFingerprintInApprovalURL() async throws {
    let first = try DeviceCandidate.generate()
    let second = try DeviceCandidate.generate()
    #expect(first.token != second.token)
    #expect(first.token.range(of: #"^lt_[0-9a-f]{48}$"#, options: .regularExpression) != nil)
    #expect(
      first.fingerprint
        == SHA256.hash(data: Data(first.token.utf8)).map { String(format: "%02x", $0) }.joined())
    let core = try EnrollmentCore()
    let approval = try await core.request(
      CoreRequests.EnrollmentApproval(
        CoreEnrollmentApprovalArgs(fingerprint: first.fingerprint, name: "Example device")))
    #expect(!approval.path.contains(first.token))
    #expect(approval.path.contains(first.fingerprint))
  }

  @Test func pollingUsesCoreDelayThenInstallsOnlyTheMatchingFullDevice() async throws {
    let candidate = try DeviceCandidate.generate()
    var reads = 0
    var clock: Double = 0
    var delays: [Double] = []
    var installed: [HubCredentials] = []
    let model = EnrollmentModel(
      candidate: { candidate }, now: { clock },
      sleep: {
        delays.append($0)
        clock += $0
      },
      request: { credentials, revoking, limit in
        #expect(!revoking && credentials.token == candidate.token && limit == 65_536)
        reads += 1
        if reads == 1 { return CoreSessionReply(status: 429, data: .null, retryAfterSeconds: 17) }
        return Self.approved(candidate)
      },
      install: { credentials, fingerprint, current in
        #expect(current() && fingerprint == candidate.fingerprint)
        installed.append(credentials)
      })
    await model.start(endpoint: "https://fixture.invalid/", name: "Example device")
    #expect(model.phase == .connected)
    #expect(delays == [17])
    #expect(
      installed == [HubCredentials(endpoint: "https://fixture.invalid", token: candidate.token)])
    #expect(model.approvalURL == nil, "A completed approval link must not linger")
  }

  @Test(arguments: ["identity", "restricted", "keychain", "workspace", "deadline"])
  func failedAttemptCannotInstallAndReportsOnlyConfirmedCleanup(reason: String) async throws {
    let candidate = try DeviceCandidate.generate()
    var clock: Double = 0
    var current = true
    var installed = 0
    var cleanup = 0
    let model = EnrollmentModel(
      candidate: { candidate }, now: { clock }, sleep: { clock += $0 }, isCurrent: { current },
      request: { credentials, revoking, _ in
        #expect(credentials.token == candidate.token)
        if revoking {
          cleanup += 1
          return CoreSessionReply(status: 401, data: .null)
        }
        if reason == "workspace" { current = false }
        if reason == "deadline" { clock = 301 }
        if reason == "identity" {
          return CoreSessionReply(
            status: 200,
            data: .object(["name": .string("device:other"), "scopes": .array([.string("full")])]))
        }
        if reason == "restricted" {
          return CoreSessionReply(
            status: 200,
            data: .object([
              "name": .string("device:" + candidate.fingerprint),
              "scopes": .array([.string("table:widgets:read")]),
            ]))
        }
        return Self.approved(candidate)
      },
      install: { _, _, _ in
        installed += 1
        throw WorkspaceError(message: "Synthetic Keychain failure", violations: [])
      })
    await model.start(endpoint: "https://fixture.invalid", name: "Example device")
    #expect(model.phase == .idle)
    #expect(installed == (reason == "keychain" ? 1 : 0))
    #expect(cleanup == 1)
    #expect(model.failure != nil)
    #expect(model.cleanupMessage?.contains("not confirmed") == true)
    #expect(model.cleanupMessage?.contains("approved later") == true)
    #expect(model.approvalURL == nil)
  }

  @Test func cancellationAndReplacementIgnoreLateApprovalAndOldCleanup() async throws {
    let first = try DeviceCandidate.generate()
    let second = try DeviceCandidate.generate()
    var generated = 0
    var held: CheckedContinuation<CoreSessionReply, Error>?
    var installed: [String] = []
    var revoked: [String] = []
    let model = EnrollmentModel(
      candidate: {
        generated += 1
        return generated == 1 ? first : second
      },
      request: { credentials, revoking, _ in
        if revoking {
          revoked.append(credentials.token)
          return CoreSessionReply(status: 200, data: .object(["logged_out": .bool(true)]))
        }
        if credentials.token == first.token {
          return try await withCheckedThrowingContinuation { held = $0 }
        }
        return Self.approved(second)
      },
      install: { credentials, _, current in
        #expect(current())
        installed.append(credentials.token)
      })
    let pending = Task { await model.start(endpoint: "https://fixture.invalid", name: "First") }
    for _ in 0..<1000 {
      if held != nil { break }
      await Task.yield()
    }
    #expect(held != nil)
    await model.cancel()
    #expect(model.cleanupMessage == "Device credential revoked.")
    await model.start(endpoint: "https://fixture.invalid", name: "Second")
    held?.resume(returning: Self.approved(first))
    await pending.value
    #expect(installed == [second.token])
    #expect(revoked == [first.token])
    #expect(model.phase == .connected && model.failure == nil)
  }

  @Test func transientNetworkFailureWaitsAndTimeoutCannotExtendThroughRetryAfter() async throws {
    let candidate = try DeviceCandidate.generate()
    var clock: Double = 0
    var reads = 0
    var delays: [Double] = []
    let model = EnrollmentModel(
      candidate: { candidate }, now: { clock },
      sleep: {
        delays.append($0)
        clock += $0
      },
      request: { _, revoking, _ in
        if revoking { return CoreSessionReply(status: 401, data: .null) }
        reads += 1
        if reads == 1 { throw URLError(.notConnectedToInternet) }
        return CoreSessionReply(status: 503, data: .null, retryAfterSeconds: 600)
      }, install: { _, _, _ in Issue.record("Installed after deadline") })
    await model.start(endpoint: "https://fixture.invalid", name: "Example device")
    #expect(reads == 2 && delays == [5, 295])
    #expect(model.failure?.contains("expired") == true)
  }

  private static func approved(_ candidate: DeviceCandidate) -> CoreSessionReply {
    CoreSessionReply(
      status: 200,
      data: .object([
        "name": .string("device:" + candidate.fingerprint), "scopes": .array([.string("full")]),
      ]))
  }
}
