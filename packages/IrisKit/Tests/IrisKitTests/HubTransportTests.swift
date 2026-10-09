import Foundation
import Testing

@testable import IrisKit

struct HubTransportTests {
  @Test func validatesCredentialsAndKeepsRequestsOnTheEndpoint() async throws {
    for endpoint in [
      "http://hub.example", "https://user:secret@hub.example", "https://hub.example?token=secret",
      "https://hub.example#fragment", "https://hub.example/\\bad",
    ] {
      #expect(throws: Error.self) { try HubTransport(endpoint: endpoint, token: "fixture-token") }
    }
    #expect(throws: Error.self) {
      try HubTransport(endpoint: "https://hub.example", token: "line\nbreak")
    }
    let hub = try HubTransport(endpoint: "https://hub.example/", token: "fixture-token")
    #expect(hub.endpoint == "https://hub.example")
    for route in ["//other.example", "/../secret", "/v1/stats?x=1", "/v1/%2fsecret"] {
      await #expect(throws: Error.self) { try await hub.post(route: route, body: [:]) }
    }
  }

  @Test func lockExcludesAnotherClientAndReleasesAfterScope() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path + ".sync.lock") }
    var first: SyncFileLock? = try SyncFileLock(databasePath: path)
    #expect(first != nil)
    #expect(throws: Error.self) { try SyncFileLock(databasePath: path) }
    first = nil
    let next = try SyncFileLock(databasePath: path)
    _ = next
  }
}
