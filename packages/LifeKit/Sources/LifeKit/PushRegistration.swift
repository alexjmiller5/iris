import Foundation
import Observation

/// One authenticated installation context. Replacing the session replaces this
/// object after invalidate(); token bytes and uncertain receipts remain in memory.
@Observable @MainActor
final class PushRegistration {
  enum Operation {
    case read(String)
    case register(CorePushRegistrationRequest)
    case revoke(CorePushRevocationRequest)
  }
  enum Reply {
    case baseline(CorePushRegistrationState?)
    case confirmed(CorePushRegistrationReceipt)
    case conflict
    case unavailable
  }
  private var confirmed = false
  private var hasIntent = false
  private var settled = false
  var revoked: Bool { valid && settled && !wantsRegistration }
  var registering: Bool { hasIntent && wantsRegistration }
  var ready: Bool { confirmed && valid && isAllowed() && token.map(isCurrentToken) == true }
  private(set) var error: String?
  private let capability: CorePushRegistrationCapability
  private let appProfile: String
  private let exchange: (Operation) async throws -> Reply
  private let isAllowed: () -> Bool
  private let isCurrentToken: (Data) -> Bool
  private var generation = 0
  private var valid = true
  private var wantsRegistration = false
  private var token: Data?
  private var pending: Operation?
  private var expectedInstallation: String?
  private var runningGeneration: Int?

  init(
    capability: CorePushRegistrationCapability, appProfile: String,
    isAllowed: @escaping () -> Bool = { true },
    isCurrentToken: @escaping (Data) -> Bool = { _ in true },
    exchange: @escaping (Operation) async throws -> Reply
  ) {
    self.capability = capability
    self.appProfile = appProfile
    self.exchange = exchange
    self.isAllowed = isAllowed
    self.isCurrentToken = isCurrentToken
  }

  func invalidate() {
    generation += 1
    valid = false
    hasIntent = false
    confirmed = false
    token = nil
    pending = nil
    error = nil
  }

  func enable(token: Data) async {
    guard valid, capability.protocol == "apns-registration-v1", !token.isEmpty,
      capability.profiles.contains(where: { exact($0.id, appProfile) })
    else { return }
    if !wantsRegistration || self.token != token {
      advance()
      hasIntent = true
      wantsRegistration = true
      self.token = token
    }
    await retry()
  }

  func tokenChanged(_ token: Data) async {
    // An OS callback cannot reverse an explicit revoke intent.
    guard valid, wantsRegistration else { return }
    await enable(token: token)
  }

  func revoke() async {
    guard valid else { return }
    beginRevocation()
    await retry()
  }

  func ensureRevoked() async {
    if !hasIntent || wantsRegistration { beginRevocation() }
    await retry()
  }

  func beginRevocation() {
    guard valid else { return }
    advance()
    hasIntent = true
    wantsRegistration = false
    token = nil
  }

  private func advance() {
    generation += 1
    settled = false
    confirmed = false
    pending = nil
    expectedInstallation = nil
    error = nil
  }

  func retry() async {
    guard valid, hasIntent, !settled, !ready, runningGeneration != generation else { return }
    let current = generation
    runningGeneration = current
    defer { if runningGeneration == current { runningGeneration = nil } }
    do {
      // A definitive CAS conflict may reconcile once. Ambiguous transport errors
      // retain the exact request ID/body, without a new baseline or token write.
      for _ in 0..<2 {
        guard isCurrent(current) else { return }
        if pending == nil {
          let reply = try await exchange(.read(appProfile))
          guard isCurrent(current) else { return }
          guard case .baseline(let state) = reply, state.map(matches) ?? true else {
            throw RegistrationError.unavailable
          }
          expectedInstallation = state?.installationId
          let requestID = UUID().uuidString
          if wantsRegistration {
            guard let token else { throw RegistrationError.unavailable }
            pending = .register(
              .init(
                appProfile: appProfile,
                deviceToken: token.map { String(format: "%02x", $0) }.joined(),
                expectedRevision: state?.revision, requestId: requestID))
          } else {
            pending = .revoke(
              .init(
                appProfile: appProfile,
                expectedRevision: state?.revision, requestId: requestID))
          }
        }
        guard isCurrent(current), let request = pending else { return }
        let reply = try await exchange(request)
        guard isCurrent(current) else { return }
        switch reply {
        case .confirmed(let receipt):
          let requestID: String
          switch request {
          case .register(let body): requestID = body.requestId
          case .revoke(let body): requestID = body.requestId
          case .read: throw RegistrationError.unavailable
          }
          guard exact(receipt.requestId, requestID), matches(receipt.registration),
            expectedInstallation.map({ exact($0, receipt.registration.installationId) }) ?? true,
            receipt.registration.state == (wantsRegistration ? .active : .revoked)
          else { throw RegistrationError.invalidReceipt }
          settled = true
          confirmed = wantsRegistration
          pending = nil
          error = nil
          return
        case .conflict:
          pending = nil
          expectedInstallation = nil
        case .unavailable, .baseline:
          throw RegistrationError.unavailable
        }
      }
      throw RegistrationError.unavailable
    } catch {
      guard isCurrent(current) else { return }
      self.error = "Push registration was not confirmed. Retry when the connection is available."
    }
  }

  private func isCurrent(_ captured: Int) -> Bool {
    valid && generation == captured && !Task.isCancelled
      && (!wantsRegistration || (isAllowed() && token.map(isCurrentToken) == true))
  }
  private func matches(_ state: CorePushRegistrationState) -> Bool {
    !state.installationId.isEmpty && !state.revision.isEmpty && state.activatedAfterSeq >= 0
      && exact(state.deploymentIdentity, capability.deploymentIdentity)
      && exact(state.sessionBinding, capability.sessionBinding)
      && exact(state.appProfile, appProfile)
  }
  private func exact(_ left: String, _ right: String) -> Bool {
    left.utf8.elementsEqual(right.utf8)
  }
  private enum RegistrationError: Error { case unavailable, invalidReceipt }
}
