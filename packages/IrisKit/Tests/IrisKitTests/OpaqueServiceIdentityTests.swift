import Foundation
import Testing

@testable import IrisKit

@MainActor
struct OpaqueServiceIdentityTests {
  #if targetEnvironment(simulator)
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["IRIS_TEST_SERVICE_ID_SIMULATOR"] != nil))
    func prepareOpaqueServiceUIFixture() async throws {
      let environment = ProcessInfo.processInfo.environment
      try #require(
        environment["IRIS_TEST_SERVICE_ID_SIMULATOR"] == environment["SIMULATOR_UDID"])
      let endpoint = try #require(environment["IRIS_TEST_SERVICE_ID_HUB"])
      let url = try #require(URL(string: endpoint))
      try #require(url.scheme == "http" && url.host == "127.0.0.1")
      let model = WorkspaceModel()
      try await model.connect(HubCredentials(endpoint: endpoint, token: "fixture"))
      try #require(model.client != nil && model.table == "widgets")
      let client = try #require(model.client)
      let hub = try HubTransport(endpoint: endpoint, token: "fixture")
      let feed = try await client.notifications(using: hub)
      #expect(
        Set(feed.notifications.map { Data($0.id.utf8) }) == [
          Data([0xc3, 0xa9]), Data([0x65, 0xcc, 0x81]),
        ])
      let usage = try await client.usage(using: hub)
      #expect(
        usage.byPrincipal.contains {
          Data($0.id.utf8) == Data("device:\u{00e9}".utf8) && $0.rowsRead == 101
        })
      #expect(
        usage.byPrincipal.contains {
          Data($0.id.utf8) == Data("device:e\u{0301}".utf8) && $0.rowsRead == 202
        })
      await model.close()
    }
  #endif
}
