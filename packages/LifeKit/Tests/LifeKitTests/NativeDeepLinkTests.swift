import Foundation
import Testing

@testable import LifeKit

struct NativeDeepLinkTests {
  private let local = NativeWorkspaceBinding.local(UUID(uuidString: "01234567-89AB-4CDE-8012-3456789ABCDE")!)

  @Test func tableViewAndRowRoundTripOpaqueUTF8WithoutNormalization() throws {
    let identifiers = ["r /?#&=%+", "café", "cafe\u{301}", "  exact  ", "\u{0000}"]
    for row in identifiers {
      for destination in [NativeDestination(table: "notes"),
        NativeDestination(table: "notes", viewID: row),
        NativeDestination(table: "notes", rowID: row),
        NativeDestination(table: "notes", viewID: "v&+/%", rowID: row)]
      {
        let link = try NativeDeepLink(destination: destination, workspace: local)
        let parsed = try NativeDeepLink(url: link.url)
        #expect(parsed == link)
        #expect(try parsed.destination(matching: local) == destination)
        #expect(link.url.scheme == "life" && link.url.host == "open" && link.url.path == "/v1")
      }
    }
    let composed = try NativeDeepLink(destination: NativeDestination(table: "notes", rowID: "café"), workspace: local)
    let decomposed = try NativeDeepLink(destination: NativeDestination(table: "notes", rowID: "cafe\u{301}"), workspace: local)
    #expect(composed != decomposed)
    #expect(Data(composed.url.absoluteString.utf8) != Data(decomposed.url.absoluteString.utf8))
  }

  @Test @MainActor func replicaUsesExistingCanonicalEndpointIdentityWithoutLeakingConnection() throws {
    let hub = try HubTransport(endpoint: "HTTPS://EXAMPLE.INVALID/service///", token: "fixture-device-token")
    let binding = NativeWorkspaceBinding.replica(canonicalEndpoint: hub.endpoint)
    let directory = WorkspaceModel.replicaURL(root: URL(fileURLWithPath: "/synthetic"), endpoint: hub.endpoint)
    #expect(binding == .replica(directory.deletingPathExtension().lastPathComponent))
    #expect(binding == .replica(canonicalEndpoint: "https://example.invalid/service"))
    let link = try NativeDeepLink(destination: NativeDestination(table: "notes", rowID: "record-id"), workspace: binding)
    let parsed = try NativeDeepLink(url: link.url)
    #expect(try parsed.destination(matching: binding) == link.destination)
    for excluded in ["example.invalid", "service", "fixture-device-token", "synthetic"] {
      #expect(!link.url.absoluteString.contains(excluded))
    }
    #expect(throws: WorkspaceError.self) {
      try parsed.destination(matching: .replica(canonicalEndpoint: "https://other.invalid/service"))
    }
    #expect(throws: WorkspaceError.self) { try parsed.destination(matching: local) }
    #expect(throws: WorkspaceError.self) { try parsed.destination(matching: nil) }
  }

  @Test func sampleCannotCopyAndLocalBindingNeverFallsBackToAnotherWorkspace() throws {
    let destination = NativeDestination(table: "same_table", rowID: "same-row")
    #expect(throws: WorkspaceError.self) { try NativeDeepLink(destination: destination, workspace: nil) }
    let link = try NativeDeepLink(destination: destination, workspace: local)
    #expect(throws: WorkspaceError.self) { try link.destination(matching: .local(UUID())) }
    #expect(throws: WorkspaceError.self) { try link.destination(matching: nil) }
  }

  @Test func encodedPlusPercentAndParameterNamesDecodeExactlyOnce() throws {
    let id = "01234567-89ab-4cde-8012-3456789abcde"
    let link = try NativeDeepLink(url: #require(URL(string:
      "life://open/v1?local=\(id)&%74able=notes&row=a+b%252Fc%26d")))
    #expect(link.destination.rowID == "a+b%2Fc&d")
    #expect(link.binding == local)
  }

  @Test func invalidEnvelopesAndAmbiguousParametersAreRejected() throws {
    let valid = "life://open/v1?local=01234567-89ab-4cde-8012-3456789abcde&table=notes"
    let invalid = [
      valid.replacingOccurrences(of: "life://", with: "life-ui://"),
      valid.replacingOccurrences(of: "/v1", with: "/v2"),
      valid.replacingOccurrences(of: "open/", with: "unknown/"),
      valid.replacingOccurrences(of: "open/", with: "user:secret@open/"),
      valid.replacingOccurrences(of: "open/", with: "open:99/"),
      valid + "#fragment", valid + "&table=other", valid + "&%74able=other",
      valid + "&row=a&row=b", valid + "&view=a&view=b", valid + "&local=other",
      valid + "&replica=" + String(repeating: "a", count: 64),
      valid + "&token=secret", valid + "&path=/some/file", valid + "&row=", valid + "&view=",
      "life://open/v1?table=notes", "life://open/v1?local=invalid&table=notes",
      "life://open/v1?replica=bad&table=notes", "life://open/v1?replica=" + String(repeating: "g", count: 64) + "&table=notes",
      valid.replacingOccurrences(of: "table=notes", with: "table="),
    ]
    for input in invalid {
      let url = try #require(URL(string: input))
      #expect(throws: WorkspaceError.self) { try NativeDeepLink(url: url) }
    }
    #expect(throws: WorkspaceError.self) {
      try NativeDeepLink(destination: NativeDestination(table: "notes", rowID: ""), workspace: local)
    }
    #expect(throws: WorkspaceError.self) {
      try NativeDeepLink(destination: NativeDestination(table: ""), workspace: local)
    }
  }
}
