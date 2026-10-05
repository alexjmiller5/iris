import Foundation
import Security
import Testing

@testable import LifeKit

struct HubCredentialsTests {
  @Test func missingEntitlementReportsSigningRepairInsteadOfUnlock() throws {
    do {
      try HubCredentialStore().check(errSecMissingEntitlement)
      Issue.record("Missing entitlement was accepted")
    } catch let error as WorkspaceError {
      #expect(error.message.contains("signing"))
      #expect(error.message.contains("-34018"))
      #expect(!error.message.contains("Unlock"))
    }
  }

  @Test func lockedKeychainStillSuggestsUnlock() throws {
    do {
      try HubCredentialStore().check(errSecInteractionNotAllowed)
      Issue.record("Locked Keychain was accepted")
    } catch let error as WorkspaceError {
      #expect(error.message.contains("Unlock"))
    }
  }

  #if os(iOS)
    @Test func keychainRoundTripUpdateAndRemoval() throws {
      let store = HubCredentialStore(service: "life-ui.fixture.\(UUID().uuidString)")
      defer { try? store.remove() }
      #expect(try store.load() == nil)
      let first = HubCredentials(endpoint: "https://fixture.invalid", token: "fixture-scoped-token")
      try store.save(first)
      #expect(try store.load() == first)
      let rotated = HubCredentials(endpoint: first.endpoint, token: "fixture-rotated-token")
      try store.save(rotated)
      #expect(try store.load() == rotated)
      try store.remove()
      #expect(try store.load() == nil)
    }
  #endif
}
