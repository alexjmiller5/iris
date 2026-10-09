import Foundation
import Testing

@testable import IrisKit

struct NativeDeepLinkTests {
  private let local = NativeWorkspaceBinding.local(UUID(uuidString: "01234567-89AB-4CDE-8012-3456789ABCDE")!)

  @Test func transientQueryLinkRoundTripsWithoutSavedViewWrites() throws {
    let state = #"{"version":2,"columns":["title"],"filters":[{"column":"title","op":"eq","value":"Synthetic"}],"sort":[{"column":"title","direction":"desc"}]}"#
    let base = try NativeDeepLink(destination: NativeDestination(table: "notes"), workspace: local)
    var parts = try #require(URLComponents(url: base.url, resolvingAgainstBaseURL: false))
    parts.queryItems!.append(URLQueryItem(name: "state", value: state))
    let link = try NativeDeepLink(url: #require(parts.url))
    let returned = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
    #expect(returned.queryItems?.first(where: { $0.name == "state" })?.value == state)
    for invalid in ["{", #"{"version":2,"actions":[]}"#, String(repeating: "x", count: 16_385)] {
      parts.queryItems = parts.queryItems?.filter { $0.name != "state" }
      parts.queryItems!.append(URLQueryItem(name: "state", value: invalid))
      #expect(throws: (any Error).self) { try NativeDeepLink(url: #require(parts.url)) }
    }
  }

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
        #expect(link.url.scheme == "iris" && link.url.host == "open" && link.url.path == "/v1")
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
      "iris://open/v1?local=\(id)&%74able=notes&row=a+b%252Fc%26d")))
    #expect(link.destination.rowID == "a+b%2Fc&d")
    #expect(link.binding == local)
  }

  @Test func invalidEnvelopesAndAmbiguousParametersAreRejected() throws {
    let valid = "iris://open/v1?local=01234567-89ab-4cde-8012-3456789abcde&table=notes"
    let invalid = [
      valid.replacingOccurrences(of: "iris://", with: "life://"),
      valid.replacingOccurrences(of: "/v1", with: "/v2"),
      valid.replacingOccurrences(of: "open/", with: "unknown/"),
      valid.replacingOccurrences(of: "open/", with: "user:secret@open/"),
      valid.replacingOccurrences(of: "open/", with: "open:99/"),
      valid + "#fragment", valid + "&table=other", valid + "&%74able=other",
      valid + "&row=a&row=b", valid + "&view=a&view=b", valid + "&local=other",
      valid + "&replica=" + String(repeating: "a", count: 64),
      valid + "&token=secret", valid + "&path=/some/file", valid + "&row=", valid + "&view=",
      "iris://open/v1?table=notes", "iris://open/v1?local=invalid&table=notes",
      "iris://open/v1?replica=bad&table=notes", "iris://open/v1?replica=" + String(repeating: "g", count: 64) + "&table=notes",
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
