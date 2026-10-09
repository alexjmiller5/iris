import Foundation
import Testing

@testable import IrisKit

@Suite(.serialized) @MainActor
struct PushRegistrationTests {
  @Test func retryWithoutIntentDoesNothingAndSuccessfulRevokeSettles() async {
    let fixture = PushRegistrationFixture()
    let client = fixture.client()
    await client.retry()
    #expect(fixture.reads == 0)
    await client.revoke()
    #expect(client.revoked)
    await client.retry()
    #expect(fixture.revocations == 1)
  }

  @Test func baselineAndTokenNeverImplyReadiness() async {
    let fixture = PushRegistrationFixture()
    fixture.holdPost = true
    let client = fixture.client()
    let registration = Task { await client.enable(token: Data([0xaa, 0xbb])) }
    await fixture.waitForPost()
    #expect(!client.ready)
    fixture.finishPost()
    await registration.value
    #expect(client.ready)
  }

  @Test func logoutAndTokenRotationRejectLateReceipts() async {
    for rotate in [false, true] {
      let fixture = PushRegistrationFixture()
      fixture.holdPost = true
      let client = fixture.client()
      let first = Task { await client.enable(token: Data([0xaa])) }
      await fixture.waitForPost()
      if rotate {
        let second = Task { await client.tokenChanged(Data([0xbb])) }
        for _ in 0..<100 where fixture.requests.count < 2 { await Task.yield() }
        fixture.finishPost(index: 0)
        await first.value
        #expect(!client.ready)
        fixture.finishPost(index: 1)
        await second.value
        #expect(client.ready)
      } else {
        client.invalidate()
        fixture.finishPost()
        await first.value
        #expect(!client.ready)
      }
    }
  }

  @Test func ambiguousResponseRetriesExactRequestWithoutReadingNewBaseline() async {
    let fixture = PushRegistrationFixture()
    fixture.failPostOnce = true
    let client = fixture.client()
    await client.enable(token: Data([0xaa]))
    #expect(!client.ready)
    await client.retry()
    #expect(client.ready)
    #expect(fixture.requests.count == 2)
    #expect(fixture.requests[0] == fixture.requests[1])
    #expect(fixture.reads == 1)
  }

  @Test func revokeDiscardsLateSuccessAndIgnoresTokenCallbacks() async {
    let fixture = PushRegistrationFixture()
    fixture.holdPost = true
    let client = fixture.client()
    let registering = Task { await client.enable(token: Data([0xaa])) }
    await fixture.waitForPost()
    await client.revoke()
    #expect(!client.ready)
    await client.tokenChanged(Data([0xbb]))
    fixture.finishPost()
    await registering.value
    #expect(!client.ready)
    #expect(fixture.requests.count == 1)
    #expect(fixture.revocations == 1)
  }

  @Test func wrongBindingOrRequestReceiptCannotSuppressPolling() async {
    for mismatch in ["deployment", "session", "profile", "request", "state"] {
      let fixture = PushRegistrationFixture()
      fixture.mismatch = mismatch
      let client = fixture.client()
      await client.enable(token: Data([0xaa]))
      #expect(!client.ready)
      #expect(client.error != nil)
    }
  }

  @Test func anotherWindowsDisableRejectsInFlightRegistration() async {
    let fixture = PushRegistrationFixture()
    fixture.holdPost = true
    let client = fixture.client()
    let registering = Task { await client.enable(token: Data([0xaa])) }
    await fixture.waitForPost()
    fixture.allowed = false
    fixture.finishPost()
    await registering.value
    #expect(!client.ready)
    fixture.allowed = true
    #expect(!client.ready, "A stale receipt must not become ready when permission returns")
  }
}

@MainActor private final class PushRegistrationFixture {
  let capability = CorePushRegistrationCapability(
    protocol: "apns-registration-v1", deploymentIdentity: "deployment", sessionBinding: "session",
    profiles: [.init(id: "desktop", platform: .macos)])
  var holdPost = false
  var failPostOnce = false
  var mismatch: String?
  var allowed = true
  var reads = 0
  var revocations = 0
  var requests: [CorePushRegistrationRequest] = []
  var continuations: [CheckedContinuation<PushRegistration.Reply, Error>?] = []

  func client() -> PushRegistration {
    PushRegistration(capability: capability, appProfile: "desktop", isAllowed: { self.allowed }) {
      operation in
      switch operation {
      case .read:
        self.reads += 1
        return .baseline(nil)
      case .register(let request):
        self.requests.append(request)
        if self.failPostOnce {
          self.failPostOnce = false
          throw URLError(.networkConnectionLost)
        }
        if self.holdPost {
          return try await withCheckedThrowingContinuation { self.continuations.append($0) }
        }
        return self.confirm(request)
      case .revoke(let request):
        self.revocations += 1
        return .confirmed(.init(requestId: request.requestId, registration: self.state(.revoked)))
      }
    }
  }
  func state(_ state: CorePushRegistrationStatus = .active) -> CorePushRegistrationState {
    .init(
      installationId: "installation", revision: "revision", state: state,
      deploymentIdentity: mismatch == "deployment" ? "other" : "deployment",
      sessionBinding: mismatch == "session" ? "other" : "session",
      appProfile: mismatch == "profile" ? "other" : "desktop", activatedAfterSeq: 0,
      updatedAt: "2026-01-01T00:00:00.000Z")
  }
  func confirm(_ request: CorePushRegistrationRequest) -> PushRegistration.Reply {
    .confirmed(
      .init(
        requestId: mismatch == "request" ? "other" : request.requestId,
        registration: state(mismatch == "state" ? .revoked : .active)))
  }
  func waitForPost() async {
    for _ in 0..<100 where continuations.isEmpty { await Task.yield() }
    #expect(!continuations.isEmpty)
  }
  func finishPost(index: Int = 0) {
    guard continuations.indices.contains(index) else {
      Issue.record("Missing held receipt")
      return
    }
    continuations[index]?.resume(returning: confirm(requests[index]))
    continuations[index] = nil
  }
}
