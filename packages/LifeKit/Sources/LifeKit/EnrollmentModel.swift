import CryptoKit
import Foundation
import Observation
import Security

struct DeviceCandidate: Sendable {
  let token: String
  var fingerprint: String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func generate() throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 24)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw WorkspaceError(
        message: "Could not generate a secure device credential.", violations: [])
    }
    return Self(token: "lt_" + bytes.map { String(format: "%02x", $0) }.joined())
  }
}

@Observable @MainActor
final class EnrollmentModel {
  enum Phase { case idle, waiting, installing, connected }
  private(set) var phase = Phase.idle
  private(set) var approvalURL: URL?
  private(set) var approvalCode: String?
  private(set) var status: String?
  private(set) var failure: String?
  private(set) var cleanupMessage: String?

  typealias Request = @MainActor (HubCredentials, Bool, Int) async throws -> CoreSessionReply
  typealias Install =
    @MainActor (HubCredentials, String, @escaping @MainActor () -> Bool) async throws -> Void
  private let candidate: @MainActor () throws -> DeviceCandidate
  private let now: @MainActor () -> Double
  private let sleep: @MainActor (Double) async throws -> Void
  private let isCurrent: @MainActor () -> Bool
  private let request: Request
  private let install: Install
  private var generation = 0
  private var polling: Task<Void, Never>?
  private var attempt: Attempt?

  private struct Attempt {
    let id: Int
    let credentials: HubCredentials
    let fingerprint: String
    let core: EnrollmentCore
    let policy: CoreEnrollmentPolicy
    let deadline: Double
  }

  init(
    candidate: @escaping @MainActor () throws -> DeviceCandidate = DeviceCandidate.generate,
    now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
    sleep: @escaping @MainActor (Double) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    },
    isCurrent: @escaping @MainActor () -> Bool = { true },
    request: @escaping Request = { credentials, revoking, limit in
      try await HubTransport(endpoint: credentials.endpoint, token: credentials.token)
        .sessionReply(revoking: revoking, maxResponseBytes: limit)
    },
    install: @escaping Install
  ) {
    self.candidate = candidate
    self.now = now
    self.sleep = sleep
    self.isCurrent = isCurrent
    self.request = request
    self.install = install
  }

  func start(endpoint: String, name: String) async {
    generation += 1
    let id = generation
    polling?.cancel()
    let previous = attempt
    attempt = nil
    if let previous { Task { _ = await self.cleanup(previous) } }
    clearApproval()
    phase = .waiting
    failure = nil
    cleanupMessage = nil
    status = "Preparing approval…"
    do {
      let candidate = try candidate()
      let hub = try HubTransport(endpoint: endpoint, token: candidate.token)
      let core = try EnrollmentCore()
      let approval = try await core.request(
        CoreRequests.EnrollmentApproval(
          CoreEnrollmentApprovalArgs(fingerprint: candidate.fingerprint, name: name)))
      guard generation == id, isCurrent(), !Task.isCancelled else { throw CancellationError() }
      let next = Attempt(
        id: id, credentials: HubCredentials(endpoint: hub.endpoint, token: candidate.token),
        fingerprint: candidate.fingerprint,
        core: core, policy: approval.policy,
        deadline: now() + Double(approval.policy.timeoutSeconds))
      attempt = next
      approvalURL = URL(string: hub.endpoint + approval.path)
      approvalCode = approval.approvalCode
      status = "Open the approval link, then approve this device in your hub."
      let task = Task { await self.poll(next) }
      polling = task
      await task.value
    } catch {
      guard generation == id else { return }
      phase = .idle
      clearApproval()
      failure =
        error is CancellationError
        ? "Approval stopped because the workspace changed." : error.localizedDescription
    }
  }

  func cancel() async {
    generation += 1
    let id = generation
    polling?.cancel()
    polling = nil
    let previous = attempt
    attempt = nil
    clearApproval()
    phase = .idle
    status = nil
    guard let previous else { return }
    cleanupMessage = "Checking whether this candidate can be revoked…"
    let result = await cleanup(previous)
    if generation == id { cleanupMessage = result }
  }

  private func check(_ attempt: Attempt) throws {
    guard attempt.id == generation, isCurrent(), !Task.isCancelled else {
      throw WorkspaceError(
        message: "Approval stopped because the workspace changed.", violations: [])
    }
    guard now() < attempt.deadline else {
      throw WorkspaceError(
        message: "This approval request expired. Start again for a new link.", violations: [])
    }
  }

  private func poll(_ attempt: Attempt) async {
    do {
      while true {
        try check(attempt)
        let reply: CoreSessionReply
        do {
          reply = try await request(attempt.credentials, false, attempt.policy.maxResponseBytes)
        } catch {
          try check(attempt)
          status = "Connection unavailable. Waiting to check approval again…"
          try await pause(attempt, seconds: Double(attempt.policy.pollIntervalSeconds))
          continue
        }
        try check(attempt)
        let result = try await attempt.core.request(
          CoreRequests.EnrollmentPollResult(
            CoreEnrollmentPollArgs(reply: reply, expectedFingerprint: attempt.fingerprint)))
        try check(attempt)
        if result.state == .approved, let session = result.session {
          guard session.replica.allowed else {
            throw WorkspaceError(
              message: session.replica.reason?.message ?? "This credential cannot sync a replica.",
              violations: [])
          }
          phase = .installing
          status = "Saving this device’s connection…"
          try await install(attempt.credentials, attempt.fingerprint) {
            (try? self.check(attempt)) != nil
          }
          // The installer checks context immediately before its synchronous commit.
          // Successful installation intentionally changes the workspace identity.
          guard generation == attempt.id else { return }
          self.attempt = nil
          phase = .connected
          status = "Device connected."
          clearApproval()
          return
        }
        status = "Waiting for approval…"
        try await pause(
          attempt, seconds: Double(result.retryAfterSeconds ?? attempt.policy.pollIntervalSeconds))
      }
    } catch {
      guard generation == attempt.id else { return }
      self.attempt = nil
      phase = .idle
      clearApproval()
      failure = error.localizedDescription
      let result = await cleanup(attempt)
      if generation == attempt.id { cleanupMessage = result }
    }
  }

  private func pause(_ attempt: Attempt, seconds: Double) async throws {
    try check(attempt)
    try await sleep(min(seconds, attempt.deadline - now()))
  }

  private func cleanup(_ attempt: Attempt) async -> String {
    // Cleanup gets its own uncancelled task and only the generated candidate token.
    await Task { @MainActor in
      do {
        let reply = try await request(attempt.credentials, true, attempt.policy.maxResponseBytes)
        let result = try await attempt.core.request(CoreRequests.SessionRevocationResult(reply))
        if result.state == .revoked { return "Device credential revoked." }
        return
          "Revocation is not confirmed. This link can still be approved later. If it is, revoke the device in your hub."
      } catch {
        return
          "Revocation is not confirmed. Check your hub’s devices and revoke this candidate if it was approved."
      }
    }.value
  }

  private func clearApproval() {
    approvalURL = nil
    approvalCode = nil
  }
}
