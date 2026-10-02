import Foundation
import Testing

@testable import LifeKit

struct HubCredentialsTests {
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
